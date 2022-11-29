
import asyncdispatch, asyncnet, strtabs, sequtils, times, os, strutils
import std/nativesockets
import std/net
import std/osproc
import std/strutils
import argparse
import std/locks
import json
import std/jsonutils

var SERVER_PORT = 8111
var SERVER_HOST = "0.0.0.0"
var sMode = "server"
const SPLITTER = "$$$"

var p = newParser:
    option("-p", "--port", default=some(getEnv("SERVER_PORT", "8111")), help="Port")
    option("-h", "--host", default=some(getEnv("SERVER_HOST", "0.0.0.0")), help="Host")

    # flag("-a", "--apple")
    # flag("-b", help="Show a banana")
    arg("mode", help="'server', 'client'")
    # arg("others", nargs = -1)

try:
    var opts = p.parse(commandLineParams())

    # assert opts.apple == true
    # assert opts.b == false
    # assert opts.output == "foo"
    # assert opts.name == "hi"
    # assert opts.others == @[]

    SERVER_PORT = parseInt(opts.port)
    SERVER_HOST = opts.host
    sMode = opts.mode

except ShortCircuit as e:
    if e.flag == "argparse_help":
        echo p.help
        quit(1)
except UsageError:
    stderr.writeLine getCurrentExceptionMsg()
    quit(1)

var
    thr: array[0..4, Thread[void]]
    L: Lock

proc fnGetMyIP():string =
    # hostname -I
    return execProcess("hostname -I").split(" ")[0]

proc fnGetMyHostname():string =
    # hostname
    return execProcess("hostname").replace("\n", "")

proc fnSendInfoToAll() =
    let fd = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, false)
    
    var oSocket = newSocket(fd, AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var iBroadcast = 1

    setSockOptInt(fd, SOL_SOCKET, SO_BROADCAST, iBroadcast)

    var sHostName = fnGetMyHostname()
    var sHostIP = fnGetMyIP()
    var sData = sHostName & SPLITTER & sHostIP & "\r\L"

    while true:
        oSocket.sendTo("255.255.255.255", Port(SERVER_PORT), sData)
        # echo "SENDING BROADCAST: " & sData
        sleep(1000)

proc fnBroadcastThreadFunc() {.thread, nimcall.} =
    fnSendInfoToAll()

proc fnServerThreadFunc() {.thread, nimcall.} =
    # Задача отлавливать все соединения и обновлять список

    var aList: seq[seq[string]] = @[]

    var server: Socket = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    server.bindAddr(Port(SERVER_PORT))
    # server.listen()
    stdout.writeLine("Server: started. Listening to new connections on port " & $(SERVER_PORT) & "...")

    while true:
        # var client: Socket = new(Socket)
        # server.accept(client)
        let sLine = waitfor server.recvFrom(255)
        echo sLine

        # var oLocal = server.getLocalAddr()
        # var oPeer = server.getPeerAddr()

        # stdout.writeLine("Server: client connected")
        # var sLine = server.recvLine()
        # echo sLine

        var oPeer = sLine.split(SPLITTER)
        aList.add(@[ $(oPeer[0]), $(oPeer[1]) ])

        if sLine == "get_list":
            client.send($(%*(aList)) & "\r\L")


proc fnClientThreadFunc() {.thread, nimcall.} =
    # Задача подключиться к серверу и вывести список

    while true:
        try:
            var aList: seq[string] = @[]

            let client: Socket = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            client.connect("127.0.0.1", Port(SERVER_PORT))
            stdout.writeLine("Client: connected to server on address 127.0.0.1:" & $(SERVER_PORT))

            try:
                while true:
                    client.send("get_list\r\L")
                    stdout.writeLine("Getting list:")
                    let message: string = client.recvLine()
                    stdout.writeLine(message)
            except:
                echo ""

            client.close()
        except:
            echo "reconnecting..."

# Запуск потоков
initLock(L)

# Оповещение всех работает всегда
# createThread(thr[0], fnBroadcastThreadFunc)

if sMode == "server":
    createThread(thr[0], fnBroadcastThreadFunc)
    createThread(thr[1], fnServerThreadFunc)

if sMode == "client":
    createThread(thr[1], fnClientThreadFunc)

joinThreads(thr)

deinitLock(L)