import imap, os, asyncdispatch

const
  hostname = "imap.spam.works"
  user = "test@spam.works"
  pass = "Abcd1234."

proc main() {.async.} =
  proc reportStatus(stat: Status) =
    echo "--- ", stat, " ---"

  let imap = newImapClient(reportStatus)
  await imap.connect(hostname, imapPort, user, pass)
  asyncCheck imap.process
  block:
    await imap.select("inbox")
  while true:
    await imap.idle()

waitFor main()
