import net, strutils, asyncnet, asyncdispatch, strscans

export Port

when defined(ssl):
  let defaultSSLContext = net.newContext(verifyMode = CVerifyNone)

const
  CRLF* = "\c\L"
  Debugging = false

type
  Status* = object
    ## Mailbox status report
    exists*: int
    recent*: int

  Imap* = ref object
    sock: AsyncSocket
    nextTag: int16

proc newImap*(sslContext = defaultSslContext): Imap =
  ## Create a new Imap instance
  new result
  result.sock = newAsyncSocket()
  sslContext.wrapSocket(result.sock)

type
  ReplyError* = object of IOError

proc quitExcpt(imap: Imap, msg: string): Future[void] =
  var retFuture = newFuture[void]()
  when Debugging:
    echo "C: QUIT"
  var sendFut = imap.sock.send("QUIT")
  sendFut.callback =
    proc () =
      raise newException(ReplyError, msg)
  return retFuture

proc checkOk(imap: Imap, tag = "*") {.async.} =
  var line = await imap.sock.recvLine()
  when Debugging:
    echo "S: ",line
  let
    elems = line.split(' ', 2)
  if elems.len == 3 and elems[0] == tag:
    case elems[1]:
      of "OK":
        return
      of "NO":
        await quitExcpt(imap, elems[2])
      else:
        discard

  await quitExcpt(imap, "Expected OK, got: " & line & " - " & $elems)

proc sendLine(imap: Imap, line: string): Future[string] {.async.} =
  let
    tag = toHex(imap.nextTag, 4)
  inc imap.nextTag
  when Debugging:
    echo "C: ",tag," ",line
  await imap.sock.send(tag&" "&line&CRLF)
  result = tag

proc dispatchLine(imap: Imap, line: string) {.async.} =
  when Debugging:
    echo "S: ", line

proc sendCmd(imap: Imap, cmd: string, args = "") {.async.} =
  let
    tag = await imap.sendLine(cmd& " "& args)
    completion = tag&" OK"
    no = tag&" NO"
  while true:
    let
      line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    if line.startsWith(completion) or line.startsWith(no):
      break
    else:
      await imap.dispatchLine(line)

proc sendCmd(imap: Imap, cmd, args: string,
             op: proc(line: string): bool) {.async.} =
  let
    tag = await imap.sendLine(cmd& " "& args)
    completion = tag&" OK"
    no = tag&" NO"
  while true:
    let
      line = await imap.sock.recvLine()
    when Debugging:
      echo "S: ", line
    if line.startsWith(completion) or line.startsWith(no):
      break
    else:
      if not op(line):
        await imap.dispatchLine(line)

proc connect*(imap: Imap, address: string, port: Port) {.async} =
  ## Establish a connection to an IMAP server
  await imap.sock.connect(address, port)
  await imap.checkOk()

proc authenticate*(imap: Imap, user, pass: string) {.async.} =
  ## Authenticate to an IMAP server
  await imap.sendCmd("LOGIN", user&" "&pass)

proc close*(imap: Imap) {.async.} =
  ## Disconnects from the SMTP server and closes the socket.
  await imap.sendCmd("LOGOUT")
  imap.sock.close()

proc noop*(imap: Imap) {.async.} =
  ## The NOOP command always succeeds.  It does nothing.
  ##
  ## Since any command can return a status update as untagged data, the
  ## NOOP command can be used as a periodic poll for new messages or
  ## message status updates during a period of inactivity (this is the
  ## preferred method to do this). The NOOP command can also be used
  ## to reset any inactivity autologout timer on the server.

  result = imap.sendCmd("NOOP")

proc create*(imap: Imap, name: string) {.async.} =
  result = imap.sendCmd("CREATE "& name)

proc store*(imap: Imap, uid: int, flags: string) {.async.} =
  result = imap.sendCmd("STORE "& $uid& " "& flags)

proc examine*(imap: Imap, name: string): Future[Status] {.async.} =
  ## The EXAMINE command is identical to SELECT and returns the same
  ## output; however, the selected mailbox is identified as read-only.
  var
    status = addr result
  let
    op = proc (line: string): bool =
      if scanf(line, "* $i EXISTS", status[].exists):
        discard
      elif scanf(line, "* $i RECENT", status[].recent):
        discard
      else:
        result = false
      true

  await imap.sendCmd("EXAMINE", name, op)

proc select*(imap: Imap, name: string): Future[Status] {.async.} =
  ## The SELECT command selects a mailbox so that messages in the
  ## mailbox can be accessed.
  var
    status = addr result
  let
    op = proc (line: string): bool =
      var n: int
      if scanf(line, "* $i EXISTS", n):
        status[].exists = n
      elif scanf(line, "* $i RECENT", n):
        status[].recent = n
      else:
        result = false
      true

  await imap.sendCmd("SELECT", name, op)

proc fetch*(imap: Imap, uid: int, items: string): Future[string] {.async.} =
  ## The FETCH command retrieves data associated with a message in the
  ## mailbox.
  var
    len: int
    id: int
    section: string
  let
    data = addr result
    op = proc (line: string): bool =
      if len > 0 and len > data[].len:
        data[].add(line)
        data[].add(CRLF)
        result = true
      if len == data[].len and line == ")":
        result = true
      elif scanf(line, "* $i FETCH ($+ {$i}", id, section, len):
         if id == uid:
           data[] = newStringOfCap(len)
           result = true

  await imap.sendCmd("FETCH", $uid& " "& items, op)

proc append*(imap: Imap, mailbox, flags, msg: string) {.async.} =
  ## Append a new message to the end of the specified destination mailbox.
  let
    tag = await imap.sendLine("APPEND " & mailbox & " ("&flags&") {"& $msg.len& "}")
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

proc search*(imap: Imap, spec: string): Future[seq[int]] {.async.} =
  ## The SEARCH command searches the mailbox for messages that match
  ## the given searching criteria.
  result = newSeq[int]()
  let
    uids = addr result
  let
    op = proc(line: string): bool =
      if line.startsWith("* SEARCH "):
        let
          elems = line.split(' ')
        uids[].setLen(elems.len-2)
        for i in 2..high(elems):
          uids[][i-2] = parseint elems[i]
        result = true

  await imap.sendCmd("SEARCH", spec, op)
