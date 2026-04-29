#!/system/xbin/luajit
-- Minimal TCP <-> serial bridge for Zigbee NCP
-- usage: luajit zb_bridge.lua /dev/ttyS5 8880

local ffi = require("ffi")

ffi.cdef[[
int open(const char *pathname, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int fcntl(int fd, int cmd, int arg);
int ioctl(int fd, unsigned long request, void *arg);

int socket(int domain, int type, int protocol);
int bind(int sockfd, const void *addr, unsigned int addrlen);
int listen(int sockfd, int backlog);
int accept(int sockfd, void *addr, unsigned int *addrlen);
int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
int shutdown(int sockfd, int how);

struct sockaddr_in {
  unsigned short sin_family;
  unsigned short sin_port;
  unsigned int   sin_addr;
  unsigned char  sin_zero[8];
};

unsigned short htons(unsigned short v);

struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);

struct termios {
  uint32_t c_iflag;
  uint32_t c_oflag;
  uint32_t c_cflag;
  uint32_t c_lflag;
  uint8_t  c_line;
  uint8_t  c_cc[19];
};

volatile int *__errno(void);
char *strerror(int errnum);
int usleep(unsigned int usec);
]]

local C = ffi.C
local function errno() return C.__errno()[0] end
local function estr() return ffi.string(C.strerror(errno())) end

-- Linux constants (verified for arm/arm64 Linux)
local AF_INET     = 2
local SOCK_STREAM = 1
local SOL_SOCKET  = 1
local SO_REUSEADDR= 2
local INADDR_ANY  = 0
local SHUT_RDWR   = 2
local O_RDWR      = 2
local O_NOCTTY    = 256
local O_NONBLOCK  = 2048   -- 0x800 on Linux/arm
local F_GETFL     = 3
local F_SETFL     = 4
local TCIOFLUSH   = 2
local TCFLSH      = 0x540B
local TCSETSF     = 0x5404
local B115200     = 0x1002
local CS8         = 0x30
local CREAD       = 0x80
local CLOCAL      = 0x800
local POLLIN      = 0x0001
local POLLERR     = 0x0008
local POLLHUP     = 0x0010
local POLLNVAL    = 0x0020

local SERIAL = arg[1] or "/dev/ttyS5"
local PORT   = tonumber(arg[2]) or 8880

local function logf(fmt, ...) io.stderr:write(string.format(fmt, ...), "\n"); io.stderr:flush() end

-- Open serial port — set termios ourselves (don't trust external stty)
local sfd = C.open(SERIAL, O_RDWR + O_NOCTTY + O_NONBLOCK)
if sfd < 0 then error("open "..SERIAL..": "..estr()) end
-- Flush pending I/O buffers like the original LifeSmart driver does
C.ioctl(sfd, TCFLSH, ffi.cast("void*", TCIOFLUSH))
-- Configure raw 115200 8N1, no flow control, no signal/echo/canonical, no
-- input or output translation. Mirrors what zdogd does via TCSETSF.
local tio = ffi.new("struct termios")
tio.c_iflag = 0
tio.c_oflag = 0
tio.c_cflag = B115200 + CS8 + CREAD + CLOCAL
tio.c_lflag = 0
tio.c_cc[6] = 1   -- VMIN
tio.c_cc[5] = 0   -- VTIME
local rc = C.ioctl(sfd, TCSETSF, tio)
if rc ~= 0 then logf("[bridge] TCSETSF failed: %s", estr()) end
logf("[bridge] opened %s fd=%d (termios set)", SERIAL, sfd)

-- Wake the EFR32: send ASH cancel + RST. On cold boot the chip is in the
-- Gecko bootloader; this sequence chains to the application.
local wake = ffi.new("uint8_t[5]", {0x1A, 0xC0, 0x38, 0xBC, 0x7E})
C.write(sfd, wake, 5)
C.usleep(500000) -- 500ms for app banner + RSTACK to arrive

-- Setup TCP listener
local lfd = C.socket(AF_INET, SOCK_STREAM, 0)
if lfd < 0 then error("socket: "..estr()) end

local one = ffi.new("int[1]", 1)
C.setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, one, 4)

local sa = ffi.new("struct sockaddr_in")
sa.sin_family = AF_INET
sa.sin_port   = C.htons(PORT)
sa.sin_addr   = INADDR_ANY
if C.bind(lfd, sa, ffi.sizeof(sa)) ~= 0 then error("bind "..PORT..": "..estr()) end
if C.listen(lfd, 1) ~= 0 then error("listen: "..estr()) end
logf("[bridge] listening on 0.0.0.0:%d", PORT)

local buf = ffi.new("uint8_t[?]", 8192)

while true do
  local cfd = C.accept(lfd, nil, nil)
  if cfd < 0 then logf("[bridge] accept: %s", estr()); break end
  -- non-blocking client
  local fl = C.fcntl(cfd, F_GETFL, 0)
  C.fcntl(cfd, F_SETFL, fl + O_NONBLOCK)
  logf("[bridge] client connected fd=%d", cfd)

  local pfds = ffi.new("struct pollfd[2]")
  pfds[0].fd = sfd; pfds[0].events = POLLIN
  pfds[1].fd = cfd; pfds[1].events = POLLIN

  local s2c, c2s = 0ULL, 0ULL
  local function dump_stats() logf("[bridge] traffic serial->tcp=%s tcp->serial=%s", tostring(s2c), tostring(c2s)) end

  while true do
    pfds[0].revents = 0; pfds[1].revents = 0
    local r = C.poll(pfds, 2, 30000)
    if r < 0 then logf("[bridge] poll: %s", estr()); break end
    if r == 0 then
      -- idle; keep going
    else
      -- serial -> tcp
      if pfds[0].revents ~= 0 then
        if bit.band(pfds[0].revents, POLLIN) ~= 0 then
          local n = C.read(sfd, buf, 8192)
          if n > 0 then
            local off = 0
            while off < tonumber(n) do
              local w = C.write(cfd, buf + off, n - off)
              if w <= 0 then logf("[bridge] tcp write: %s", estr()); pfds[1].revents = POLLHUP; break end
              off = off + tonumber(w)
            end
            s2c = s2c + n
          end
        end
        if bit.band(pfds[0].revents, POLLERR + POLLHUP + POLLNVAL) ~= 0 then
          logf("[bridge] serial fd error/hup")
          break
        end
      end
      -- tcp -> serial
      if pfds[1].revents ~= 0 then
        if bit.band(pfds[1].revents, POLLIN) ~= 0 then
          local n = C.read(cfd, buf, 8192)
          if n <= 0 then logf("[bridge] client closed (read=%d)", tonumber(n)); break end
          local off = 0
          while off < tonumber(n) do
            local w = C.write(sfd, buf + off, n - off)
            if w <= 0 then logf("[bridge] serial write: %s", estr()); break end
            off = off + tonumber(w)
          end
          c2s = c2s + n
        end
        if bit.band(pfds[1].revents, POLLERR + POLLHUP + POLLNVAL) ~= 0 then
          logf("[bridge] client hup")
          break
        end
      end
    end
  end

  dump_stats()
  C.shutdown(cfd, SHUT_RDWR)
  C.close(cfd)
end

C.close(sfd)
C.close(lfd)
