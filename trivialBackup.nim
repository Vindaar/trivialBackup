
import os, osproc
import logging, times
import strformat, strutils, sequtils

const logPath = "logs/trivialBackup.log"
const pathList = "pathList.txt"
const backupPath = "backupToPath.txt"
let archiveFreq = initDuration(days = 7)      # frequency of archives in days
let sleepDuration = initDuration(hours = 1)
const maxTarRetries = 5

var L = newConsoleLogger()
var fL = newFileLogger(logPath, fmtStr = verboseFmtStr)
addHandler(L)
addHandler(fL)

var daemonSleeping = false

# TODO: set up such that we can safely stop the daemon
proc setKeyboardInterruptHandler() {.noconv.} =
  ## this is called if the user stops the program with Ctrl+C
  # what to do? should in principle wait until backup procedure
  # is done
  if daemonSleeping:
    info "Daemon safely stopped via Ctrl+C while it was sleeping."
    quit()
  else:
    warn "Daemon unsafely stopped via Ctrl+C while backup was running!"
    warn "Check the log and check the backups!"
    quit()

proc strJoin(args: varargs[string]): string =
  ## joins the given strings
  result = ""
  for a in args:
    result.add a & " "

proc parsePathList(): seq[string] =
  ## given a filename to a file containing a list of
  ## files, returns a list of paths to be backed up
  result = pathList.readFile.splitLines.filterIt(it.len > 0)
  info "The following paths will be backed up:"
  for l in result:
    info &"\t {l}"

proc parseBackupToFile(): string =
  ## parses the file containing the path to which we wish to
  ## backup
  result = backupPath.readFile.strip
  info &"Backup up to {result}"
  let existed = existsOrCreateDir(result)
  if existed:
    logging.info &"Backup location `{result}` already exists."
  else:
    logging.info &"Backup location `{result}` created."

proc execCmdTB(cmd, descr: string): bool =
  info &"calling {descr} cmd: {cmd}"
  let (outp, errC) = execCmdEx(cmd)
  info "Return value: ", errC
  info "Output: " & outp
  result = if errC != 0: false else: true

proc createArchive(p, to: string): bool =
  ## creates an archive of the given path
  # TODO: we currently create the archive from the source
  # location. Do we want to do that?
  # output path
  let pathName = p.splitPath[1]
  let archiveName = to / &"{pathName}_{getTime().toUnix}"
  info &"Creating archive {archiveName}"

  result = false
  var retryCount = 0
  while not result and retryCount < maxTarRetries:
    when defined(windows):
      raise newException(Exception, "Archive creation not yet supported on Windows.")
    else:
      let
        app = "tar"
        args = "-czf"
        fname = archiveName & ".tar.gz"
        cmd = strJoin(app, args, fname, p)
      result = execCmdTB(cmd, "archive")
      if not result:
        # tar unsuccessful, remove tar archive and try again
        info "Creating tar archive {fname} unsuccessful. Removing file " &
          "and trying again... {retryCount} / {maxTarRetries}"
        removeFile(fname)
        inc retryCount

proc createArchiveIfNeeded(p, to: string) =
  ## checks whether we want to create an archive of
  ## the given path and performs it if needed
  ## determined by age of last backup, if any.
  let archivePath = to / "archives"
  let existed = existsOrCreateDir(archivePath)
  if existed:
    info &"Archive location `{archivePath}` already exists."
  else:
    info &"Archive location `{archivePath}` created."

  # now check oldest archive
  var tdiff: seq[Duration]
  let pathName = p.splitPath[1]
  let walkPattern = archivePath / (pathName & "*.tar.gz")
  for f in walkFiles(walkPattern):
    tdiff.add (getTime() - getCreationTime(f))

  var createBackup = false
  var minDiff: Duration
  if tdiff.len > 0:
    minDiff = min(tdiff)
    if minDiff > archiveFreq:
      createBackup = true
  else:
    createBackup = true
    minDiff = initDuration(seconds = int.high)
  if createBackup:
    # create an archive
    let success = createArchive(p, archivePath)
    if not success:
      warn &"Error during creation of archive for {p}"
      warn "See the log for more information."
  else:
    info &"Last archive of {p} is only {minDiff} old, skipping archive."

proc performBackup(p: string, backupPath: string): bool =
  ## performs an incremental backup of the given path and
  ## returns a bool. true if successful
  # depending on whether we run on windows or linux, get the correct
  # command we execute
  info &"Backup up {p}"
  let to = backupPath #getBackupPath(p, backupPath)

  when defined(windows):
    # perform backup using robocopy
    raise newException(Exception, "Not yet implemented!")
  else:
    # build command to be executed using rsync
    let
      app = "rsync"
      args = "-aP"
      cmd = strJoin(app, args, p, to)
    result = execCmdTB(cmd, "backup")

proc daemon() =
  ## contains the event loop

  while true:
    # first get paths to be backed up / archived
    # allows to add diretories while daemon is running
    let files = parsePathList()
    let to = parseBackupToFile()
    # perform incremental backup
    var success: bool
    for f in files:
      success = f.performBackup(to)
      if not success:
        warn &"There were errors raised during backup of {f}"
        warn "See the log file for more information"

    # now that backup is done, create archive if needed
    for f in files:
      f.createArchiveIfNeeded(to)

    # before we sleep, flush to disk
    fL.file.flushFile()
    info &"... daemon will sleep for {sleepDuration}"
    daemonSleeping = true
    sleep(sleepDuration.seconds.int * 1000)
    daemonSleeping = false
    info &"... daemon woke up"



when isMainModule:
  setControlCHook(hook = setKeyboardInterruptHandler)
  daemon()
