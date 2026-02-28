#include <Arduino.h>
#include <PDM.h>
#include <bluefruit.h>

// Friend-compatible UUIDs:
// Service: 19B10000-E8F2-537E-4F6C-D104768A1214
// Audio  : 19B10001-E8F2-537E-4F6C-D104768A1214 (Read + Notify)
// Format : 19B10002-E8F2-537E-4F6C-D104768A1214 (Read, CODEC_ID)
#define FRIEND_AUDIO_UUID(val)                                              \
  (const uint8_t[]) {                                                        \
    0x14, 0x12, 0x8A, 0x76, 0x04, 0xD1, 0x6C, 0x4F,                         \
    0x7E, 0x53, 0xF2, 0xE8, static_cast<uint8_t>((val) & 0xFF),             \
    static_cast<uint8_t>(((val) >> 8) & 0xFF), 0xB1, 0x19                   \
  }

constexpr const char* DEVICE_NAME = "Friend";

// Friend default PCM format (CODEC_ID=1): PCM16 LE @ 8 kHz.
constexpr uint8_t CODEC_ID_PCM16_8K = 1;

// Mic capture (input) and codec framing.
constexpr int MIC_SAMPLE_RATE = 16000;
constexpr int MIC_CHANNELS = 1;
constexpr int MIC_GAIN = 64;
constexpr uint32_t MIC_RETRY_INTERVAL_MS = 2000;

constexpr size_t CODEC_PACKAGE_SAMPLES = 160;  // 10 ms at 16 kHz
constexpr size_t CODEC_DIVIDER = 2;            // 16 kHz -> 8 kHz
constexpr size_t CODEC_OUTPUT_SAMPLES = CODEC_PACKAGE_SAMPLES / CODEC_DIVIDER; // 80
constexpr size_t CODEC_OUTPUT_BYTES = CODEC_OUTPUT_SAMPLES * sizeof(int16_t);  // 160 bytes

// Friend transport framing per BLE notify packet:
// [0..1] = packet id (LE), [2] = chunk index, [3..] = codec bytes.
constexpr size_t NET_BUFFER_HEADER_SIZE = 3;
constexpr size_t MAX_NOTIFY_BYTES = 244;

// Small queue to absorb BLE backpressure.
constexpr size_t TX_QUEUE_FRAMES = 48;
constexpr size_t PCM_ACCUMULATOR_CAPACITY = CODEC_PACKAGE_SAMPLES * 4;

BLEService audioService(FRIEND_AUDIO_UUID(0x0000));
BLECharacteristic audioDataCharacteristic(FRIEND_AUDIO_UUID(0x0001));
BLECharacteristic audioFormatCharacteristic(FRIEND_AUDIO_UUID(0x0002));

volatile bool microphoneReady = false;
volatile uint16_t activeConnHandle = BLE_CONN_HANDLE_INVALID;
volatile uint16_t packetNextIndex = 0;
volatile uint32_t droppedFrameCount = 0;

uint32_t lastMicInitAttemptMs = 0;

volatile size_t pcmAccumulatorCount = 0;
int16_t pcmAccumulator[PCM_ACCUMULATOR_CAPACITY];

volatile uint16_t queueHead = 0;
volatile uint16_t queueTail = 0;
uint8_t frameQueue[TX_QUEUE_FRAMES][CODEC_OUTPUT_BYTES];

void preparePdmPins() {
#if defined(PIN_PDM_DIN) && defined(PIN_PDM_CLK) && defined(PIN_PDM_PWR)
  PDM.setPins(PIN_PDM_DIN, PIN_PDM_CLK, PIN_PDM_PWR);
  if (PIN_PDM_PWR >= 0) {
    pinMode(PIN_PDM_PWR, OUTPUT);
    digitalWrite(PIN_PDM_PWR, HIGH);
    delay(10);
  }
#endif
}

void clearStreamingBuffers() {
  noInterrupts();
  packetNextIndex = 0;
  droppedFrameCount = 0;
  queueHead = 0;
  queueTail = 0;
  pcmAccumulatorCount = 0;
  interrupts();
}

bool queueFrameFromISR(const uint8_t* encodedFrame) {
  uint16_t head = queueHead;
  uint16_t nextHead = (head + 1) % TX_QUEUE_FRAMES;
  if (nextHead == queueTail) {
    droppedFrameCount++;
    return false;
  }

  memcpy(frameQueue[head], encodedFrame, CODEC_OUTPUT_BYTES);
  queueHead = nextHead;
  return true;
}

bool dequeueFrame(uint8_t* outFrame) {
  bool hasFrame = false;

  noInterrupts();
  if (queueTail != queueHead) {
    uint16_t tail = queueTail;
    queueTail = (tail + 1) % TX_QUEUE_FRAMES;
    memcpy(outFrame, frameQueue[tail], CODEC_OUTPUT_BYTES);
    hasFrame = true;
  }
  interrupts();

  return hasFrame;
}

void encodeAndQueueFrameFromISR() {
  uint8_t encoded[CODEC_OUTPUT_BYTES];
  for (size_t i = 0; i < CODEC_OUTPUT_SAMPLES; ++i) {
    int16_t sample = pcmAccumulator[i * CODEC_DIVIDER];
    encoded[i * 2] = static_cast<uint8_t>(sample & 0xFF);
    encoded[i * 2 + 1] = static_cast<uint8_t>((sample >> 8) & 0xFF);
  }

  queueFrameFromISR(encoded);

  size_t currentCount = pcmAccumulatorCount;
  size_t remaining = currentCount - CODEC_PACKAGE_SAMPLES;
  if (remaining > 0) {
    memmove(pcmAccumulator, pcmAccumulator + CODEC_PACKAGE_SAMPLES, remaining * sizeof(int16_t));
  }
  pcmAccumulatorCount = remaining;
}

void onPDMData() {
  static int16_t captureBuffer[256];

  int bytesAvailable = PDM.available();
  while (bytesAvailable > 0) {
    int bytesToRead = bytesAvailable;
    if (bytesToRead > static_cast<int>(sizeof(captureBuffer))) {
      bytesToRead = sizeof(captureBuffer);
    }

    int bytesRead = PDM.read(captureBuffer, bytesToRead);
    if (bytesRead <= 0) {
      break;
    }

    int sampleCount = bytesRead / static_cast<int>(sizeof(int16_t));
    size_t localCount = pcmAccumulatorCount;

    for (int i = 0; i < sampleCount; ++i) {
      if (localCount >= PCM_ACCUMULATOR_CAPACITY) {
        droppedFrameCount++;
        break;
      }

      pcmAccumulator[localCount++] = captureBuffer[i];
      pcmAccumulatorCount = localCount;

      if (localCount >= CODEC_PACKAGE_SAMPLES) {
        encodeAndQueueFrameFromISR();
        localCount = pcmAccumulatorCount;
      }
    }

    pcmAccumulatorCount = localCount;
    bytesAvailable -= bytesRead;
  }
}

bool tryStartMicrophone() {
  if (microphoneReady) {
    return true;
  }

  lastMicInitAttemptMs = millis();

  PDM.end();
  preparePdmPins();

  if (PDM.begin(MIC_CHANNELS, MIC_SAMPLE_RATE)) {
    PDM.setGain(MIC_GAIN);
    microphoneReady = true;
    Serial.println("PDM microphone ready @ 16kHz");
    return true;
  }

  microphoneReady = false;
  PDM.end();
  Serial.println("PDM microphone start failed (need XIAO nRF52840 Sense board setting)");
  return false;
}

size_t getMaxNotifyPayload() {
  size_t payload = 20; // ATT MTU 23 fallback
  if (activeConnHandle != BLE_CONN_HANDLE_INVALID) {
    BLEConnection* connection = Bluefruit.Connection(activeConnHandle);
    if (connection != nullptr) {
      uint16_t mtu = connection->getMtu();
      if (mtu > 3) {
        payload = mtu - 3;
      }
    }
  }
  if (payload > MAX_NOTIFY_BYTES) {
    payload = MAX_NOTIFY_BYTES;
  }
  return payload;
}

bool notifyWithRetry(const uint8_t* packet, size_t length, uint32_t timeoutMs = 2000) {
  uint32_t start = millis();
  while (Bluefruit.connected()) {
    if (audioDataCharacteristic.notify(packet, static_cast<uint16_t>(length))) {
      return true;
    }
    if (millis() - start > timeoutMs) {
      return false;
    }
    delay(1);
  }
  return false;
}

bool sendFrameAsFriendPackets(const uint8_t* frame, uint16_t packetId) {
  if (!Bluefruit.connected() || !audioDataCharacteristic.notifyEnabled()) {
    return false;
  }

  size_t payloadCapacity = getMaxNotifyPayload();
  if (payloadCapacity <= NET_BUFFER_HEADER_SIZE) {
    return false;
  }

  size_t maxChunkBytes = payloadCapacity - NET_BUFFER_HEADER_SIZE;
  maxChunkBytes &= ~static_cast<size_t>(1); // Keep PCM16 sample boundaries.
  if (maxChunkBytes == 0) {
    return false;
  }

  static uint8_t packet[MAX_NOTIFY_BYTES];
  size_t offset = 0;
  uint8_t chunkIndex = 0;

  while (offset < CODEC_OUTPUT_BYTES) {
    size_t bytesToSend = CODEC_OUTPUT_BYTES - offset;
    if (bytesToSend > maxChunkBytes) {
      bytesToSend = maxChunkBytes;
    }

    packet[0] = static_cast<uint8_t>(packetId & 0xFF);
    packet[1] = static_cast<uint8_t>((packetId >> 8) & 0xFF);
    packet[2] = chunkIndex++;
    memcpy(packet + NET_BUFFER_HEADER_SIZE, frame + offset, bytesToSend);

    if (!notifyWithRetry(packet, bytesToSend + NET_BUFFER_HEADER_SIZE)) {
      return false;
    }

    offset += bytesToSend;
  }

  return true;
}

void connectCallback(uint16_t connHandle) {
  activeConnHandle = connHandle;
  clearStreamingBuffers();
  Serial.println("BLE connected");
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  if (activeConnHandle == connHandle) {
    activeConnHandle = BLE_CONN_HANDLE_INVALID;
  }
  clearStreamingBuffers();
  Serial.print("BLE disconnected, reason=");
  Serial.println(reason);
}

void setupBLE() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.configUuid128Count(3);
  Bluefruit.begin();
  Bluefruit.setName(DEVICE_NAME);
  Bluefruit.setTxPower(4);

  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Periph.setConnInterval(6, 20); // 7.5 ms to 25 ms

  audioService.begin();

  audioDataCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  audioDataCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  audioDataCharacteristic.setMaxLen(MAX_NOTIFY_BYTES);
  audioDataCharacteristic.begin();

  audioFormatCharacteristic.setProperties(CHR_PROPS_READ);
  audioFormatCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  audioFormatCharacteristic.setFixedLen(1);
  audioFormatCharacteristic.begin();
  audioFormatCharacteristic.write8(CODEC_ID_PCM16_8K);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(audioService);
  Bluefruit.ScanResponse.addName();

  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void setupMicrophone() {
  PDM.onReceive(onPDMData);
  tryStartMicrophone();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("Starting Friend-format BLE PCM streamer...");

#if defined(ARDUINO_Seeed_XIAO_nRF52840_Sense)
  Serial.println("Board macro: ARDUINO_Seeed_XIAO_nRF52840_Sense");
#elif defined(ARDUINO_Seeed_XIAO_nRF52840)
  Serial.println("Board macro: ARDUINO_Seeed_XIAO_nRF52840 (non-Sense)");
#else
  Serial.println("Board macro: unknown (verify board selection)");
#endif

  setupBLE();
  setupMicrophone();

  Serial.println("Ready. Continuous Friend-style audio notifications enabled.");
}

void loop() {
  if (!microphoneReady) {
    uint32_t now = millis();
    if (now - lastMicInitAttemptMs >= MIC_RETRY_INTERVAL_MS) {
      tryStartMicrophone();
    }
  }

  if (Bluefruit.connected() && audioDataCharacteristic.notifyEnabled()) {
    static uint8_t frame[CODEC_OUTPUT_BYTES];
    while (dequeueFrame(frame)) {
      uint16_t packetId;
      noInterrupts();
      packetId = packetNextIndex++;
      interrupts();

      if (!sendFrameAsFriendPackets(frame, packetId)) {
        break;
      }
    }
  }

  delay(1);
}
