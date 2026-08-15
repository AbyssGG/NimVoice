## audio.nim
## Handles writing raw float PCM data to a WAV file format.

import streams

proc writeWav*(filename: string, pcmData: seq[float32], sampleRate: int = 22050, volume: float = 1.0, speed: float = 1.0, pitch: float = 1.0) =
  var f = newFileStream(filename, fmWrite)
  if f == nil:
    raise newException(IOError, "Cannot open file for writing: " & filename)
  
  defer: f.close()

  let numChannels = 1
  let bitsPerSample = 16
  
  # Adjust pitch by modifying sample rate (also affects speed, but we compensate with resampling)
  let effectiveSampleRate = int(float(sampleRate) * pitch)
  let byteRate = effectiveSampleRate * numChannels * bitsPerSample div 8
  let blockAlign = numChannels * bitsPerSample div 8
  
  # Resample for speed compensation
  # If we just changed pitch, speed changed by 1/pitch.
  # To achieve target speed, we need to resample by factor = pitch / speed.
  let resampleFactor = pitch / speed
  let newLen = int(float(pcmData.len) / resampleFactor)
  var processedData = newSeq[float32](newLen)
  
  for i in 0 ..< newLen:
    let origIdx = float(i) * resampleFactor
    let idx1 = int(origIdx)
    let idx2 = min(idx1 + 1, pcmData.len - 1)
    let frac = origIdx - float(idx1)
    if idx1 < pcmData.len:
      processedData[i] = pcmData[idx1] * (1.0 - frac) + pcmData[idx2] * frac
    else:
      processedData[i] = 0.0

  # PCM data is float32 [-1.0, 1.0], we convert it to int16
  var int16Data = newSeq[int16](processedData.len)
  for i in 0 ..< processedData.len:
    var sample = processedData[i] * volume
    if sample > 1.0: sample = 1.0
    if sample < -1.0: sample = -1.0
    int16Data[i] = int16(sample * 32767.0)

  let dataChunkSize = int16Data.len * 2
  let riffChunkSize = 36 + dataChunkSize

  # RIFF chunk
  f.write("RIFF")
  f.write(int32(riffChunkSize))
  f.write("WAVE")

  # fmt chunk
  f.write("fmt ")
  f.write(int32(16)) # fmt chunk size
  f.write(int16(1))  # format: PCM
  f.write(int16(numChannels))
  f.write(int32(effectiveSampleRate))
  f.write(int32(byteRate))
  f.write(int16(blockAlign))
  f.write(int16(bitsPerSample))

  # data chunk
  f.write("data")
  f.write(int32(dataChunkSize))
  
  if int16Data.len > 0:
    f.writeData(addr int16Data[0], dataChunkSize)
