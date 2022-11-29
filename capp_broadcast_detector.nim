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

var BROADCAST_SERVER_PORT = 8111
var SERVER_PORT = 8112
var SERVER_HOST = "0.0.0.0"
var sMode = "server"
const BROADCAST_IP = "255.255.255.255"
const SPLITTER = "$$$"
const TABLE_CLEAN_TIMEOUT = 10000
const TIMEOUT_SLEEP = 100
const TIMEOUT_SENDER_SLEEP = 1000
const DATA_LEN = 1000
const CMD_GET_LIST = "get_list"

var p = newParser:
    option("-p", "--port", default=some(getEnv("SERVER_PORT", "8111")), help="Port")
    option("-h", "--host", default=some(getEnv("SERVER_HOST", "0.0.0.0")), help="Host")
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

proc fnGetMyIP():string =
    # hostname -I
    return execProcess("hostname -I").split(" ")[0]

proc fnGetMyHostname():string =
    # hostname
    return execProcess("hostname").replace("\n", "")    

proc fnSendInfoToAll() =
    # Отправка данных о клиенте
    # - Хост
    # - IP

    let fd = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, false)
    
    var oSocket = newSocket(fd, AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var iBroadcast = 1

    setSockOptInt(fd, SOL_SOCKET, SO_BROADCAST, iBroadcast)

    var sHostName = fnGetMyHostname().replace("\r\n", "")
    var sHostIP = fnGetMyIP().replace("\r\n", "")
    var sData = sHostName & SPLITTER & sHostIP & "\r\L"

    while true:
        var buf = newStringOfCap(DATA_LEN)
        buf.addStr(sData)
        oSocket.sendTo(BROADCAST_IP, Port(BROADCAST_SERVER_PORT), buf)
        sleep(TIMEOUT_SENDER_SLEEP)

proc fnBroadcastThreadFunc() {.thread, nimcall.} =
    fnSendInfoToAll()

proc fnBroadcastServer() {.thread, nimcall.} =
    var aList = initTable[string,string]()

    var socket = newSocket(
        Domain.AF_INET,
        SockType.SOCK_DGRAM,
        Protocol.IPPROTO_UDP,
        buffered = false
    )
    var oP = Port(BROADCAST_SERVER_PORT)
    var sH = "0.0.0.0"
    socket.getFd().setBlocking(false)
    socket.bindAddr(oP, sH)

    echo "Listenting for UDP on 0.0.0.0:" & $(BROADCAST_SERVER_PORT)
    var iTimeout = TABLE_CLEAN_TIMEOUT

    while true:
        try:
            var sBuffer = newStringOfCap(DATA_LEN)
            var iBufLen = socket.recvFrom(sBuffer, DATA_LEN, sH, oP)
        
            # echo "> " & sBuffer

            var aBuffer = sBuffer.split(SPLITTER)

            if aBuffer[0] == CMD_GET_LIST:
                var sSendBuffer = newStringOfCap(DATA_LEN)
                var sSendData = $(%*(aList))
                sSendBuffer.addStr(sSendData)

                socket.sendTo(sH, oP, sSendBuffer)
            else:
                aList[aBuffer[1]] = aBuffer[0]

                iTimeout -= 1

                if iTimeout == 0:
                    # Очистка списка
                    iTimeout = TABLE_CLEAN_TIMEOUT
                    aList.clear()
        except:
            sleep(TIMEOUT_SLEEP)

proc fnPrintTable(oTable: OrderedTable[string, JsonNode]) = 
    eraseScreen() #puts cursor at down
    setCursorPos(0, 0)
    let t2 = newUnicodeTable()
    t2.separateRows = false
    t2.setHeaders(@[newCell("Host", pad=5), newCell("IP", rightpad=20)])

    for sRawIP, oRawHost in oTable:
        var sHost = oRawHost.getStr()
        var sIP = sRawIP.replace(" ", "").replace("\n", "").replace("\r", "")
        t2.addRow(@[sHost, sIP])
    
    printTable(t2)

proc fnClientThreadFunc() {.thread, nimcall.} =
    # Задача подключиться к серверу и вывести список
    var aList = initTable[string,string]()

    var socket = newSocket(
        Domain.AF_INET,
        SockType.SOCK_DGRAM,
        Protocol.IPPROTO_UDP,
        buffered = false
    )
    var oP = Port(BROADCAST_SERVER_PORT)
    var sH = "127.0.0.1"
    socket.getFd().setBlocking(false)
    # socket.bindAddr(oP, sH)

    echo "Connecting to UDP on 127.0.0.1:" & $(BROADCAST_SERVER_PORT)

    while true:
        try:
            var sBuffer = newStringOfCap(DATA_LEN)
            sBuffer.addStr(CMD_GET_LIST)
            # echo "> " & sBuffer
            socket.sendTo(sH, oP, sBuffer)
            var sRecvHost:string
            var sRecvPort:Port

            var iRecvBufLen = socket.recvFrom(sBuffer, DATA_LEN, sRecvHost, sRecvPort)

            var oTable = parseJson(sBuffer).getFields()
            fnPrintTable(oTable)

            sleep(TIMEOUT_SLEEP*10)
        except:
            sleep(TIMEOUT_SLEEP)

var
    thr: array[0..4, Thread[void]]
    L: Lock

# Запуск потоков
initLock(L)

# Оповещение всех работает всегда
createThread(thr[0], fnBroadcastThreadFunc)

if sMode == "server":
    # createThread(thr[1], fnServerThreadFunc)
    createThread(thr[2], fnBroadcastServer)

if sMode == "client":
    createThread(thr[1], fnClientThreadFunc)

joinThreads(thr)

deinitLock(L)