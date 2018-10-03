import net, strutils, asyncnet, asyncFutures, asyncdispatch, strscans, tables, deques, parseutils, strformat

export Port

when not defined(ssl):
  {.error: "IMAP client requires -d:ssl".}

const
  imapPort* = 993.Port
  CRLF* = "\c\L"
  Debugging = defined(debugImap)

type
  LineCallback = proc (line: string): bool

  Status* = object
    ## Mailbox status report
    exists*: int
    recent*: int

  StatusCallback* = proc (st: Status)

  ImapClient* = ref object
    sslContext: SslContext
    sock: AsyncSocket
    tagAlloc: int16
    tagCallbacks: Table[string, LineCallback]
    anyCallbacks: Deque[LineCallback]
    status: Status
    statCb: StatusCallback

proc complete(st: Status): bool =
  (-1 < st.exists) and (-1 < st.recent)

proc reset(st: var Status) =
  st.exists = -1
  st.recent = -1

proc nextTag(imap: ImapClient): string =
  inc imap.tagAlloc
  toHex(imap.tagAlloc, 4)

proc finished(st: Status): bool =
  st.exists > -1 and st.recent > -1

proc newImapClient*(cb: StatusCallback): ImapClient =
  ## Create a new Imap instance
  result = ImapClient(
    sslContext: net.newContext(verifyMode = CVerifyNone),
    sock: newAsyncSocket(),
    tagCallbacks: initTable[string, LineCallback](4),
    anyCallbacks: initDeque[LineCallback](4),
    statCb: cb)
  wrapSocket(result.sslContext, result.sock)
  reset result.status

type
  ReplyError* = object of IOError

proc quitExcpt(imap: ImapClient, msg: string) =
  when Debugging:
    echo "C: QUIT"
  discard imap.sock.send("QUIT")
  raise newException(ReplyError, msg)

proc checkOk(imap: ImapClient, tag = "*") {.async.} =
  var line = await imap.sock.recvLine()
  when Debugging:
    echo "S: ",line
  let elems = line.split(' ', 2)
  if elems.len == 3 and elems[0] == tag:
    case elems[1]:
      of "OK":
        return
      of "NO":
        quitExcpt(imap, elems[2])
      else:
        discard
  quitExcpt(imap, fmt"Expected OK, got: {line} - {$elems}")

proc assertOk(imap: ImapClient; line: string; tag = "*") =
  let elems = line.split(' ', 2)
  if elems.len == 3:
    case elems[1]:
      of "OK":
        return
      of "NO":
        quitExcpt(imap, elems[2])
      else:
        discard
  quitExcpt(imap, fmt"Expected OK, got: {line} - {$elems}")

proc sendLine(imap: ImapClient; line: string): Future[void] =
  when Debugging:
    echo "C: ", line
  imap.sock.send(line & CRLF)

proc sendTag(imap: ImapClient; cb: LineCallback; cmd: string): Future[void] =
  let tag = imap.nextTag
  imap.tagCallbacks[tag] = cb
  imap.sendLine(fmt"{tag} {cmd}")

proc dispatchLine(imap: ImapClient; line: string) {.async.} =
  when Debugging:
    echo "S: ", line

proc sendCmd(imap: ImapClient, cmd: string, args = "") {.async.} =
  let tag = imap.nextTag
  await imap.sendLine(fmt"{tag} {cmd} {args}")
  let
    completion = tag & " OK"
    no = tag & " NO"
    bad = tag & " BAD"
  while true:
    let line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    if line.startsWith(completion) or line.startsWith(no):
      break
    if line.startsWith(bad):
      imap.sock.close()
      raise newException(IOError, line)
    else:
      await imap.dispatchLine(line)

proc sendCmd(imap: ImapClient; cmd, args: string, op: LineCallback) {.async.} =
  let tag = imap.nextTag
  await imap.sendLine(fmt"{tag} {cmd} {args}")
  let
    completion = tag & " OK"
    no = tag & " NO"
    bad = tag & " BAD"
  while true:
    let line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    echo "line: ", line
    if line.startsWith(completion) or line.startsWith(no):
      break
    if line.startsWith(bad):
      imap.sock.close()
      raise newException(IOError, line)
    else:
      if not op(line):
        await imap.dispatchLine(line)

proc sendAny(imap: ImapClient; cb: LineCallback; cmd: string, args = ""): Future[void] =
  let tag = imap.nextTag
  imap.anyCallbacks.addLast cb
  if args == "":
    imap.sendLine(fmt"{tag} {cmd}")
  else:
    imap.sendLine(fmt"{tag} {cmd} {args}")

proc connect*(imap: ImapClient; host: string, port = imapPort) {.async} =
  ## Establish a connection to an IMAP server
  await imap.sock.connect(host, port)
  await imap.checkOk()

proc authenticate*(imap: ImapClient; user, pass: string) {.async.} =
  ## Authenticate to an IMAP server
  await imap.sendCmd("LOGIN", fmt"{user} {pass}")

proc connect*(imap: ImapClient; host: string; port: Port; user, pass: string) {.async.} =
  ## Connect and authenticate to an IMAP server
  await imap.connect(host, port)
  await imap.authenticate(user, pass)

proc close*(imap: ImapClient) {.async.} =
  ## Disconnects from the SMTP server and closes the socket.
  await imap.sendCmd("LOGOUT")
  close imap.sock
  destroyContext imap.sslContext

proc noop*(imap: ImapClient) {.async.} =
  ## The NOOP command always succeeds.  It does nothing.
  ##
  ## Since any command can return a status update as untagged data, the
  ## NOOP command can be used as a periodic poll for new messages or
  ## message status updates during a period of inactivity (this is the
  ## preferred method to do this). The NOOP command can also be used
  ## to reset any inactivity autologout timer on the server.
  await imap.sendCmd("NOOP")

proc create*(imap: ImapClient; name: string) {.async.} =
  await imap.sendCmd(fmt"CREATE {name}")

proc store*(imap: ImapClient; uid: int, flags: string) {.async.} =
  await imap.sendCmd(fmt"STORE {$uid} {flags}")

proc examine*(imap: ImapClient; name: string): Future[void] =
  ## The EXAMINE command is identical to SELECT and returns the same
  ## output; however, the selected mailbox is identified as read-only.
  let
    recv = newFuture[void]()
    cb = proc (line: string): bool =
      imap.assertOk(line)
      recv.complete()
      true
    send = imap.sendTag(cb, fmt"EXAMINE {name}")
  all(send, recv)

proc select*(imap: ImapClient; name: string): Future[void] =
  ## The SELECT command selects a mailbox so that messages in the
  ## mailbox can be accessed.
  let
    recv = newFuture[void]()
    cb = proc (line: string): bool =
      imap.assertOk(line)
      recv.complete()
      true
    send = imap.sendTag(cb, fmt"SELECT {name}")
  all(send, recv)

proc fetch*(imap: ImapClient; uid: int, items: string): Future[string] {.async.} =
  ## The FETCH command retrieves data associated with a message in the
  ## mailbox.
  var
    len: int
    id: int
    section: string
    data: string
  let cb = proc(line: string): bool =
    if scanf(line, "* $i FETCH ($+ {$i}", id, section, len):
      if id != uid:
        return
    var line = waitFor imap.sock.recv(len)
    when Debugging:
      echo "S: ", line
    data.add line
    while true:
      var line = waitFor imap.sock.recvLine()
      when Debugging:
        echo "S: ", line
      if line == ")":
        break
      elif scanf(line, " $+ {$i}", section, len):
        var line = waitFor imap.sock.recv(len)
        when Debugging:
          echo "S: ", line
        data.add line

    result = true
  imap.anyCallbacks.addLast cb
  await imap.sendCmd("FETCH", fmt"{$uid} {items}")
  return data

proc append*(imap: ImapClient, mailbox, flags, msg: string) {.async.} =
  let tag = imap.nextTag
  ## Append a new message to the end of the specified destination mailbox.
  await imap.sendLine(fmt"{tag} APPEND {mailbox} {flags} {$msg.len}")
  while true:
    let line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    if not line.startswith("+"):
      await imap.dispatchLine(line)
    else:
      when Debugging:
        echo "C: ", msg
      await imap.sock.send(msg)
      await imap.sock.send(CRLF)
      await imap.checkOk(tag)
      return

proc search*(imap: ImapClient; spec: string): Future[seq[int]] {.async.} =
  ## The SEARCH command searches the mailbox for messages that match
  ## the given searching criteria.
  var uids = newSeq[int]()
  let op = proc(line: string): bool =
    if line.startsWith("* SEARCH "):
      let elems = line.split(' ')
      uids.setLen(elems.len-2)
      for i in 2..high(elems):
        uids[i-2] = parseint elems[i]
      result = true
  imap.anyCallbacks.addLast op
  await imap.sendCmd("SEARCH", spec)
  return uids

proc process*(imap: ImapClient): Future[void] {.async.} =
  ## Process messages from the IMAP server
  ## until the connection is closed.
  while not imap.sock.isClosed:
    let line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    if line[0] == '*':
      for _ in 1..imap.anyCallbacks.len:
        let cb = imap.anyCallbacks.popFirst()
        if not cb(line):
          imap.anyCallbacks.addLast cb
      var n = -1
      if scanf(line, "* $i EXISTS", n):
        if n != imap.status.exists:
          imap.status.exists = n
      if scanf(line, "* $i RECENT", n):
        if n != imap.status.recent:
          imap.status.recent = n
      if imap.status.complete:
        imap.statCb(imap.status)
        reset imap.status
    else:
      var tag = newStringOfCap(4)
      if line.parseUntil(tag, ' ') > 0:
        let cb = imap.tagCallbacks.getOrDefault(tag)
        if not cb.isNil and cb(line):
          imap.tagCallbacks.del(tag)
        else:
          if line.startsWith(fmt"{tag} BAD"):
            raise newException(IOError, line)

proc idle*(imap: ImapClient): Future[void] {.async.} =
  var stat = Status(exists: -1, recent: -1)
  let
    fut = newFuture[void]()
    cb = proc (line: string): bool =
      var n: int
      if scanf(line, "* $i EXISTS", n):
        stat.exists = n
      elif scanf(line, "* $i RECENT", n):
        stat.recent = n
      if stat.finished:
        fut.complete()
        result = true # idle complete
  while true:
    await imap.sendAny(cb, "IDLE")
    let done = await withTimeout(fut, 29 * 60 * 1000)
    await imap.sendLine("DONE")
    if done: break
