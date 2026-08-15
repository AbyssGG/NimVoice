import std/json
import std/strutils
import std/tables
import std/unicode

proc loadVocab*(path: string): Table[string, int64] =
  result = initTable[string, int64]()
  let j = parseJson(readFile(path))
  for k, v in j.pairs:
    result[k] = v.getInt().int64

var pinyinDict: Table[string, string]
var pinyinLoaded = false

proc loadPinyinDict*(path = "../pinyin_dict.json") =
  if pinyinLoaded: return
  try:
    let j = parseJson(readFile(path))
    for k, v in j.pairs:
      pinyinDict[k] = v.getStr()
    pinyinLoaded = true
  except:
    echo "[WARNING] Failed to load pinyin dict from ", path
    discard

proc getPinyin*(c: string): string =
  loadPinyinDict()
  if pinyinDict.hasKey(c):
    return pinyinDict[c]
  return c

proc numberToWords*(n: int): string =
  let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
              "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
              "seventeen", "eighteen", "nineteen"]
  let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

  if n == 0: return "zero"
  if n < 20: return ones[n]
  if n < 100:
    let suffix = if n mod 10 != 0: " " & ones[n mod 10] else: ""
    return tens[n div 10] & suffix
  if n < 1000:
    let suffix = if n mod 100 != 0: " and " & numberToWords(n mod 100) else: ""
    return ones[n div 100] & " hundred" & suffix
  if n < 1000_000:
    let suffix = if n mod 1000 != 0: " " & numberToWords(n mod 1000) else: ""
    return numberToWords(n div 1000) & " thousand" & suffix
  if n < 1000_000_000:
    let suffix = if n mod 1000_000 != 0: " " & numberToWords(n mod 1000_000) else: ""
    return numberToWords(n div 1000_000) & " million" & suffix
  $n

proc normalizeText*(text: string): string =
  var normalized = ""
  var i = 0
  let runes = toRunes(text)
  for r in runes:
    let s = $r
    if s.len > 0 and s[0] in {'0'..'9'}:
      normalized.add(s) # numbers handled differently or just keep them
    else:
      let py = getPinyin(s)
      if py != s:
        normalized.add(" " & py & " ")
      else:
        normalized.add(s)
  
  # second pass for numbers
  var finalNormalized = ""
  i = 0
  while i < normalized.len:
    if normalized[i] in {'0'..'9'}:
      var numStr = ""
      while i < normalized.len and normalized[i] in {'0'..'9'}:
        numStr.add(normalized[i])
        i += 1
      try:
        finalNormalized.add(numberToWords(parseInt(numStr)))
      except ValueError:
        finalNormalized.add(numStr)
    else:
      finalNormalized.add(normalized[i])
      i += 1

  # replace multiple spaces with single space
  finalNormalized = finalNormalized.replace("  ", " ").strip()
  finalNormalized.toLowerAscii()

proc tokenize*(text: string, vocab: Table[string, int64]): seq[int64] =
  result = newSeq[int64]()
  let eId = vocab.getOrDefault("</s>", 2)
  let unkId = vocab.getOrDefault("<unk>", 3)
  let spaceId = vocab.getOrDefault("\xE2\x96\x81", 4)

  let normText = normalizeText(text)
  result.add(spaceId)
  for c in normText:
    if c == ' ':
      result.add(spaceId)
    else:
      result.add(vocab.getOrDefault($c, unkId))
  result.add(eId)

proc readRawFile*(path: string): seq[float32] =
  var f = open(path, fmRead)
  defer: f.close()

  let size = getFileSize(f)
  result = newSeq[float32](size div 4)
  if result.len > 0:
    discard f.readBuffer(addr result[0], size)
