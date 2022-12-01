import std/[times, os]
import math
import strformat
import times, os
import json

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

var iT1 = getTime().toUnix()
echo $(iT1)

sleep(10000)

var iT2 = parseJson($(%*(getTime().toUnix()))).getInt()
echo $(iT2)

echo fnGetDiffTimeFormat(10)
echo fnGetDiffTimeFormat(40)
echo fnGetDiffTimeFormat(120)
echo fnGetDiffTimeFormat(100000)
echo fnGetDiffTimeFormat(cast[int](iT2) - cast[int](iT1))
