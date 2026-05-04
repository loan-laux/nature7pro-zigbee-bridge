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
local SO_KEEPALIVE= 9
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

-- Tunables
-- Consecutive (c2s>0, s2c=0) sessions before we trigger an EFR32 rewake.
local MAX_DEAD_SESSIONS = 3
-- In-session: HA most recently sent data, but the chip has been silent past
-- this long => declare wedge and exit(1) for rewake. Set well above bellows'
-- ~12 s heartbeat timeout so we don't rewake on a single laggy heartbeat.
local CHIP_TIMEOUT_S    = 60
-- Whole session has had zero bytes either way for this long => close the
-- client (HA can reconnect). Catches bellows holding a zombie TCP socket
-- without sending heartbeats.
local IDLE_TIMEOUT_S    = 300
-- Poll wakeup so we can re-check the timeouts above without depending on
-- traffic to drive the loop.
local POLL_TIMEOUT_MS   = 2000

-- Direct-syscall logger: bypass Lua's buffered io.stderr. A single fwrite
-- error (e.g. transient ENOSPC) puts the FILE* in a sticky error state and
-- silently swallows every subsequent line, which once cost us 18 hours of
-- visibility into a wedged bridge. write(2) has no such trap.
local logbuf_size = 1024
local logbuf = ffi.new("char[?]", logbuf_size)
local function logf(fmt, ...)
  local line = os.date("%Y-%m-%d %H:%M:%S ") .. string.format(fmt, ...) .. "\n"
  if #line > logbuf_size then line = line:sub(1, logbuf_size - 1) .. "\n" end
  ffi.copy(logbuf, line)
  C.write(2, logbuf, #line)
end

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
local dead_sessions = 0

while true do
  local cfd = C.accept(lfd, nil, nil)
  if cfd < 0 then logf("[bridge] accept: %s", estr()); break end
  -- non-blocking client + TCP keepalive so dead peers eventually surface as POLLHUP
  local fl = C.fcntl(cfd, F_GETFL, 0)
  C.fcntl(cfd, F_SETFL, fl + O_NONBLOCK)
  C.setsockopt(cfd, SOL_SOCKET, SO_KEEPALIVE, one, 4)
  logf("[bridge] client connected fd=%d", cfd)

  local pfds = ffi.new("struct pollfd[2]")
  pfds[0].fd = sfd; pfds[0].events = POLLIN
  pfds[1].fd = cfd; pfds[1].events = POLLIN

  local s2c, c2s = 0ULL, 0ULL
  local t_start    = os.time()
  local last_s2c_t = t_start
  local last_c2s_t = t_start
  local wedge_exit = false

  while true do
    pfds[0].revents = 0; pfds[1].revents = 0
    local r = C.poll(pfds, 2, POLL_TIMEOUT_MS)
    if r < 0 then logf("[bridge] poll: %s", estr()); break end

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
          last_s2c_t = os.time()
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
        last_c2s_t = os.time()
      end
      if bit.band(pfds[1].revents, POLLERR + POLLHUP + POLLNVAL) ~= 0 then
        logf("[bridge] client hup")
        break
      end
    end

    -- In-session liveness checks (driven by POLL_TIMEOUT_MS wakeups so they
    -- still fire when neither fd is producing events).
    local now = os.time()
    -- Wedge: HA was the most recent sender, and the chip has been silent
    -- past CHIP_TIMEOUT_S. exit(1) so the watchdog re-runs natureinitrd.lua.
    if tonumber(c2s) > 0 and last_c2s_t > last_s2c_t and (now - last_s2c_t) > CHIP_TIMEOUT_S then
      logf("[bridge] in-session wedge: chip silent %ds while HA active (c2s=%s s2c=%s)",
           now - last_s2c_t, tostring(c2s), tostring(s2c))
      wedge_exit = true
      break
    end
    -- Idle: nothing either way for IDLE_TIMEOUT_S. Drop the client (no rewake)
    -- — covers bellows holding a zombie socket after giving up heartbeats.
    if (now - last_s2c_t) > IDLE_TIMEOUT_S and (now - last_c2s_t) > IDLE_TIMEOUT_S then
      logf("[bridge] session idle %ds — dropping client", now - last_s2c_t)
      break
    end
  end

  logf("[bridge] traffic serial->tcp=%s tcp->serial=%s", tostring(s2c), tostring(c2s))
  C.shutdown(cfd, SHUT_RDWR)
  C.close(cfd)

  if wedge_exit then
    logf("[bridge] in-session wedge — exiting with code 1 to trigger EFR32 rewake")
    C.close(lfd); C.close(sfd)
    os.exit(1)
  end

  -- Post-session detector: HA sent bytes but the chip never replied.
  if tonumber(c2s) > 0 and tonumber(s2c) == 0 then
    dead_sessions = dead_sessions + 1
    logf("[bridge] dead session %d/%d (chip silent)", dead_sessions, MAX_DEAD_SESSIONS)
    if dead_sessions >= MAX_DEAD_SESSIONS then
      logf("[bridge] chip wedged — exiting with code 1 to trigger EFR32 rewake")
      C.close(lfd)
      C.close(sfd)
      os.exit(1)
    end
  elseif tonumber(s2c) > 0 and tonumber(c2s) > 0 then
    dead_sessions = 0
  end
end

C.close(sfd)
C.close(lfd)
