import net, strutils, asyncnet, asyncdispatch, strscans

export Port

when defined(ssl):
  let defaultSSLContext = net.newContext(verifyMode = CVerifyNone)

const
  CRLF* = "\c\L"
  Debugging = not defined(release)

type
  Status* = object
    ## Mailbox status report
    exists*: int
    recent*: int

  ImapClientBase*[SocketType] = ref object
    sock: SocketType
    nextTag: int16

  ImapClient* = ImapClientBase[Socket]
  AsyncImapClient* = ImapClientBase[AsyncSocket]

proc newImap*(sslContext = defaultSslContext): ImapClient =
  ## Create a new Imap instance
  new result
  result.sock = newSocket()
  sslContext.wrapSocket(result.sock)

proc newAsyncImap*(sslContext = defaultSslContext): AsyncImapClient =
  ## Create a new Imap instance
  new result
  result.sock = newAsyncSocket()
  sslContext.wrapSocket(result.sock)

type
  ReplyError* = object of IOError

proc quitExcpt(imap: ImapClient, msg: string) =
  when Debugging:
    echo "C: QUIT"
  imap.sock.send("QUIT")
  raise newException(ReplyError, msg)

proc quitExcpt(imap: AsyncImapClient, msg: string): Future[void] =
  when Debugging:
    echo "C: QUIT"
  var
    retFuture = newFuture[void]()
    sendFut = imap.sock.send("QUIT")
  sendFut.callback =
    proc () =
      raise newException(ReplyError, msg)
  return retFuture

proc checkOk(imap: ImapClient | AsyncImapClient, tag = "*") {.multisync.} =
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

proc sendLine(imap: ImapClient | AsyncImapClient, line: string): Future[string] {.multisync.} =
  let
    tag = toHex(imap.nextTag, 4)
  inc imap.nextTag
  when Debugging:
    echo "C: ",tag," ",line
  await imap.sock.send(tag&" "&line&CRLF)
  result = tag

proc dispatchLine(imap: ImapClient | AsyncImapClient, line: string) {.multisync.} =
  when Debugging:
    echo "S: ", line

proc sendCmd(imap: ImapClient | AsyncImapClient, cmd: string, args = "") {.multisync.} =
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

proc sendCmd(imap: ImapClient | AsyncImapClient, cmd, args: string,
             op: proc(line: string): bool) {.multisync.} =
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

proc connect*(imap: ImapClient, address: string, port: Port) =
  ## Establish a connection to an IMAP server
  imap.sock.connect(address, port)
  imap.checkOk()

proc connect*(imap: AsyncImapClient, address: string, port: Port) {.async} =
  ## Establish a connection to an IMAP server
  await imap.sock.connect(address, port)
  await imap.checkOk()

proc authenticate*(imap: ImapClient | AsyncImapClient, user, pass: string) {.multisync.} =
  ## Authenticate to an IMAP server
  await imap.sendCmd("LOGIN", user&" "&pass)

proc close*(imap: ImapClient | AsyncImapClient) {.multisync.} =
  ## Disconnects from the SMTP server and closes the socket.
  await imap.sendCmd("LOGOUT")
  imap.sock.close()

proc noop*(imap: ImapClient | AsyncImapClient) {.multisync.} =
  ## The NOOP command always succeeds.  It does nothing.
  ##
  ## Since any command can return a status update as untagged data, the
  ## NOOP command can be used as a periodic poll for new messages or
  ## message status updates during a period of inactivity (this is the
  ## preferred method to do this). The NOOP command can also be used
  ## to reset any inactivity autologout timer on the server.

  await imap.sendCmd("NOOP")

proc create*(imap: ImapClient | AsyncImapClient, name: string) {.multisync.} =
  await imap.sendCmd("CREATE "& name)

proc store*(imap: ImapClient | AsyncImapClient, uid: int, flags: string) {.multisync.} =
  await imap.sendCmd("STORE "& $uid& " "& flags)

proc examine*(imap: ImapClient | AsyncImapClient, name: string): Future[Status] {.multisync.} =
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

proc select*(imap: ImapClient | AsyncImapClient, name: string): Future[Status] {.multisync.} =
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

proc fetch*(imap: ImapClient | AsyncImapClient, uid: int, items: string): Future[string] {.multisync.} =
  ## The FETCH command retrieves data associated with a message in the
  ## mailbox.
  var
    len: int
    id: int
    section: string
  let
    tag = await imap.sendLine("FETCH $# $#" % [$uid, items])
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
      if scanf(line, "* $i FETCH ($+ {$i}", id, section, len):
        if id == uid:
          result = await imap.sock.recv(len)
      else:
        await imap.dispatchLine(line)

proc append*(imap: ImapClient | AsyncImapClient,
             mailbox, flags, msg: string) {.multisync.} =
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

proc search*(imap: ImapClient | AsyncImapClient, spec: string): Future[seq[int]] {.multisync.} =
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
