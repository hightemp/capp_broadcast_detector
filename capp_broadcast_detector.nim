import argparse
import std/locks
import json
import std/jsonutils
import std/osproc
import std/nativesockets
import std/net
import flatty/binny
import tables
import terminaltables
import terminal
import yaml
import std/[threadpool, asyncdispatch, asyncnet]
import std/[times, os]
import math
import strformat 

# NOTE: Константы
const DEFAULT_HOST = "0.0.0.0"
const BROADCAST_IP = "255.255.255.255"
const SPLITTER = "$$$"
const TABLE_CLEAN_TIMEOUT = 10000
const TIMEOUT_BROADCAST_SERVER_SLEEP = 300
const TIMEOUT_COMMAND_SERVER_SLEEP = 100
const TIMEOUT_CLIENT_SLEEP = 100
const TIMEOUT_SENDER_SLEEP = 100
const DATA_LEN = 10000
const CMD_GET_LIST = "get_list"
const CONFIG_FILE = "config.yaml"

# NOTE: Переменные
var BROADCAST_SERVER_PORT = 8111
var SERVER_PORT = 8112
var SERVER_HOST = DEFAULT_HOST
var sMode = "server"

# NOTE: Парсинг параметров
var p = newParser:
    option("-p", "--port", default=some(getEnv("SERVER_PORT", "8111")), help="Port")
    option("-h", "--host", default=some(getEnv("SERVER_HOST", DEFAULT_HOST)), help="Host")
    option("-P", "--broadcast_port", default=some(getEnv("BROADCAST_SERVER_PORT", "8112")), help="Port")

    arg("mode", help="'server', 'client'")

try:
    var opts = p.parse(commandLineParams())

    SERVER_PORT = parseInt(opts.port)
    SERVER_HOST = opts.host
    BROADCAST_SERVER_PORT = parseInt(opts.broadcast_port)
    sMode = opts.mode

except ShortCircuit as e:
    if e.flag == "argparse_help":
        echo p.help
        quit(1)
except UsageError:
    stderr.writeLine getCurrentExceptionMsg()
    quit(1)


type ServerMachine = object
    ip: string
    mac{.defaultVal: "".}: string

type ServerConfig = object
    machines: seq[ServerMachine]

# NOTE: Методы для получения данных
proc fnFilter(n: string): string = 
    return n.replace(" ", "").replace("\n", "").replace("\r", "")

proc fnFilterTime(n: string): string = 
    return n.replace("T", " ").replace("+03:00", "")

proc fnGetMyIP():string =
    # hostname -I
    return execProcess("hostname -I").split(" ")[0]

proc fnGetMyHostname():string =
    # hostname
    return execProcess("hostname").replace("\n", "")

proc fnGetIterfaces():string =
    return execProcess("tcpdump -D")

proc fnGetFirstIterface():string =
    return execProcess("tcpdump -D | head -n 1 | awk '{ print $1 }' | egrep -o '([a-z][a-z0-9]+)'").fnFilter()

proc fnGetFirstIterfaceMAC():string =
    var sIn = fnGetFirstIterface()
    return execProcess(&"cat /sys/class/net/{sIn}/address")

proc fnGetUptime():string =
    return execProcess("cat /proc/uptime").replace("\n", "")

proc fnGetCPUStat():string =
    return execProcess("cat /proc/stat").replace("\n", "")

proc fnGetCPULoad():string =
    return execProcess("cat /proc/stat |grep cpu |tail -1|awk '{print ($5*100)/($2+$3+$4+$5+$6+$7+$8+$9+$10)}'|awk '{print 100-$1}'").replace("\n", "")

proc fnGetMemInfo():string =
    return execProcess("cat /proc/meminfo").replace("\n", "")

# NOTE: [!!] fnBroadcastThreadFunc
proc fnBroadcastThreadFunc() {.async.}=
    # Отправка данных о клиенте
    # - Хост
    # - IP

    let fd = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, false)
    var oSocket = newSocket(fd, AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    setSockOptInt(fd, SOL_SOCKET, SO_BROADCAST, 1)

    var iStartTimestamp = getTime().toUnix()

    proc fnTemp1(fd: AsyncFD):bool =
        var oT = getTime()

        var sData = $(%*{
            "start_timestamp": iStartTimestamp,
            "last_active": $oT,
            "host": fnGetMyHostname(),
            "ip": fnGetMyIP(),
            "mac": fnGetFirstIterfaceMAC(),
            "uptime": fnGetUptime(),
            "cpu_info": fnGetCPUStat(),
            "cpu_load": fnGetCPULoad(),
            "mem_info": fnGetMemInfo(),
        })
        var buf = newStringOfCap(DATA_LEN)
        buf.addStr(sData)
        oSocket.sendTo(BROADCAST_IP, Port(BROADCAST_SERVER_PORT), buf)
    
    addTimer(TIMEOUT_SENDER_SLEEP, false, fnTemp1)

# NOTE: Потоковые переменные
var oConfig {.threadvar.}: ServerConfig
var aList {.threadvar.}: Table[string, JsonNode]

proc fnLoadConfig() = # : ServerConfig =
    if fileExists(CONFIG_FILE):
        var sString = readFile(CONFIG_FILE)
        load(sString, oConfig)

proc fnGetDiffTimeFormat(iDiffTimestamp: int): string =
    var fTime = iDiffTimestamp.toFloat()
    var iSec = math.floor(fTime).toInt() %% 60
    fTime = fTime/60
    var iMin = math.floor(fTime).toInt() %% 60
    fTime = fTime/60
    var iHour = math.floor(fTime).toInt() %% 24
    fTime = fTime/24

    var sHour: string = if iHour>9: $iHour else: "0" & $iHour
    var sMin: string = if iMin>9: $iMin else: "0" & $iMin
    var sSec: string = if iSec>9: $iSec else: "0" & $iSec

    return &"{sHour}:{sMin}:{sSec}"

proc fnUpdateList() =
    for sIP, oNode in aList:
        # var oTable = oNode.getFields()
        var iStartDiffTimestamp = cast[int](getTime().toUnix() - oNode["start_timestamp"].getInt())        
        var iUpdateDiffTimestamp = cast[int](getTime().toUnix() - oNode["update_timestamp"].getInt())
        oNode["timestamp_diff"] = %*(iStartDiffTimestamp)

        if iUpdateDiffTimestamp > 0 and iUpdateDiffTimestamp < 30:
            oNode["is_active"] = %*("Y")
        else: 
            oNode["is_active"] = %*("N")

# NOTE: [!!] fnBroadcastServer
proc fnBroadcastServer() {.async.}=
    aList = initTable[string,JsonNode]()

    # Сервер оповещений
    var socket1 = newSocket(
        Domain.AF_INET,
        SockType.SOCK_DGRAM,
        Protocol.IPPROTO_UDP,
        buffered = false
    )
    var oP1 = Port(BROADCAST_SERVER_PORT)
    var sH1 = DEFAULT_HOST
    socket1.getFd().setBlocking(false)
    socket1.bindAddr(oP1, sH1)

    echo "SERVER1 Listenting for UDP on 0.0.0.0:" & $(BROADCAST_SERVER_PORT)
    # var iTimeout = TABLE_CLEAN_TIMEOUT

    proc fnTemp21(fd: AsyncFD):bool = # BROADCAST_SERVER_PORT
        try:
            var oRP1 = Port(0)
            var sRH1 = DEFAULT_HOST
            var sBuffer1 = newStringOfCap(DATA_LEN)
            var iBufLen1 = socket1.recvFrom(sBuffer1, DATA_LEN, sRH1, oRP1)

            if iBufLen1>0:
                # echo sBuffer1
                # echo $(%*(aList))
                var oBuffer1 = parseJson(sBuffer1).getFields()
                var sIP: string = oBuffer1["ip"].getStr()

                aList[sIP] = %*(oBuffer1)
                aList[sIP]["update_timestamp"] = %*(getTime().toUnix())

                # iTimeout -= 1

                # if iTimeout == 0:
                #     # Очистка списка
                #     iTimeout = TABLE_CLEAN_TIMEOUT
                #     aList.clear()

            fnUpdateList()

        except:
            # var currException = getCurrentException()
            # var msg = currException.getStackTrace() & "Error: unhandled exception: " & currException.msg & " [" & $currException.name & "]"
            # echo "ERROR 1 " & msg
            discard
    
    addTimer(TIMEOUT_BROADCAST_SERVER_SLEEP, false, fnTemp21)

# NOTE: [!!] fnCommandServer
proc fnCommandServer() {.async.}=
    aList = initTable[string,JsonNode]()

    # Сервер tui данных
    var socket2 = newSocket(
        Domain.AF_INET,
        SockType.SOCK_DGRAM,
        Protocol.IPPROTO_UDP,
        buffered = false
    )
    var oP2 = Port(SERVER_PORT)
    var sH2 = DEFAULT_HOST
    socket2.getFd().setBlocking(false)
    socket2.bindAddr(oP2, sH2)

    echo "SERVER2 Listenting for UDP on 0.0.0.0:" & $(SERVER_PORT)
    
    proc fnTemp22(fd: AsyncFD):bool = # SERVER_PORT
        try:
            var oRP2 = Port(0)
            var sRH2 = DEFAULT_HOST
            var sBuffer2 = newStringOfCap(DATA_LEN)
            var iBufLen2 = socket2.recvFrom(sBuffer2, DATA_LEN, sRH2, oRP2)

            # echo "> " & sBuffer2
            if iBufLen2>0:

                if sBuffer2 == CMD_GET_LIST:
                    var sSendBuffer = newStringOfCap(DATA_LEN)
                    var sSendData = $(%*(aList))
                    sSendBuffer.addStr(sSendData)

                    socket2.sendTo(sRH2, oRP2, sSendBuffer)
        except:
            # var currException = getCurrentException()
            # var msg = currException.getStackTrace() & "Error: unhandled exception: " & currException.msg & " [" & $currException.name & "]"
            # echo "ERROR 2: " & msg
            discard
    
    addTimer(TIMEOUT_COMMAND_SERVER_SLEEP, false, fnTemp22)

proc fnPrintTable(oTable: OrderedTable[string, JsonNode]) = 
    eraseScreen() #puts cursor at down
    setCursorPos(0, 0)
    let t2 = newUnicodeTable()
    t2.separateRows = false
    
    t2.setHeaders(@[
        newCell(""), 
        newCell("last active"), 
        newCell("active"), 
        newCell("host"), 
        newCell("ip"),
        newCell("mac")
    ])

    for sRawIP, oNode in oTable:
        var sIP = oNode["ip"].getStr().fnFilter()
        var sMAC = oNode["mac"].getStr().fnFilter()
        var sHost = oNode["host"].getStr()
        var sIsActive = oNode["is_active"].getStr()
        var sLastActive = oNode["last_active"].getStr().fnFilterTime()
        var sTimeActive = fnGetDiffTimeFormat(oNode["timestamp_diff"].getInt())

        t2.addRow(@[
            sIsActive,
            sLastActive,
            sTimeActive,
            sHost, 
            sIP,
            sMAC
        ])
    
    printTable(t2)

# NOTE: [!!] fnClientThreadFunc
proc fnClientThreadFunc() {.async.}=
    # Задача подключиться к серверу и вывести список

    var socket = newSocket(
        Domain.AF_INET,
        SockType.SOCK_DGRAM,
        Protocol.IPPROTO_UDP,
        buffered = false
    )
    var oConnectP = Port(SERVER_PORT)
    var sConnectH = "127.0.0.1"
    socket.getFd().setBlocking(false)

    echo "Connecting to UDP on 127.0.0.1:" & $(SERVER_PORT)

    proc fnTemp3(fd: AsyncFD):bool =
        try:
            socket.connect(sConnectH, oConnectP)
            var sBuffer = newStringOfCap(DATA_LEN)
            sBuffer.addStr(CMD_GET_LIST)
            # echo "> " & sBuffer
            socket.sendTo(sConnectH, oConnectP, sBuffer)
            
            var sRecvHost:string
            var sRecvPort:Port

            var iRecvBufLen = socket.recvFrom(sBuffer, DATA_LEN, sRecvHost, sRecvPort)

            var oTable = parseJson(sBuffer).getFields()

            fnPrintTable(oTable)
        except:
            # var currException = getCurrentException()
            # var msg = currException.getStackTrace() & "Error: unhandled exception: " & currException.msg & " [" & $currException.name & "]"
            # echo "ERROR: " & msg
            discard

    addTimer(TIMEOUT_CLIENT_SLEEP, false, fnTemp3)

# NOTE: main
proc main() {.async.} =
    fnLoadConfig()

    if sMode == "server":
        var F1 = fnBroadcastThreadFunc()
        var F2 = fnBroadcastServer()
        var F3 = fnCommandServer()
        await F1
        await F2
        await F3

    if sMode == "client":
        var F1 = fnClientThreadFunc()
        await F1

    # sync()

waitFor main()
runForever()