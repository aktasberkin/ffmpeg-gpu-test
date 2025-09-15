# GPU HLS Transcoding Test Suite for L40S

## Amaç
CPU-yoğun FFmpeg HLS transcoding işlemlerini GPU'ya taşıyarak 100-200 concurrent RTSP stream işleyebilmek.

## Mevcut Durum vs Hedef

### Mevcut (CPU)
- **Komut**: libx264, CRF 36, preset medium
- **Kapasite**: 10 kamera zor (16 core CPU'da)
- **CPU Kullanımı**: %80-90
- **Problem**: Thread explosion, yüksek CPU yükü

### Hedef (GPU - L40S)
- **Komut**: h264_nvenc, CQ 36, preset p4
- **Kapasite**: 100-200 concurrent stream
- **CPU Kullanımı**: %10-20
- **Avantaj**: Hardware acceleration, düşük güç tüketimi

## Test Script'leri

### 1. `generate-test-sources.sh`
Test video kaynaklarını oluşturur:
- Synthetic test patterns
- Sample video downloads
- 200+ kaynak için genişletilmiş liste

### 2. `gpu-optimized-hls.sh`
Senin exact use case'ini GPU ile test eder:
- HLS output (segment_*.ts + playlist.m3u8)
- Aynı kalite ayarları (CRF 36 equivalent)
- Progressive load testing (2→200 streams)

### 3. `ultimate-gpu-test.sh`
Maximum kapasite testi:
- Detaylı monitoring (GPU, VRAM, NVENC, CPU)
- Otomatik limit detection
- Performance report generation

### 4. `setup-runpod-l40s.sh`
RunPod ortamını hazırlar:
- NVIDIA driver & CUDA
- FFmpeg with NVENC
- Monitoring tools
- Performance tuning

## RunPod'da Kullanım

```bash
# 1. RunPod'a bağlan
ssh root@your-runpod-instance

# 2. Script'leri yükle
git clone <your-repo> /workspace/ffmpeg-gpu-test
cd /workspace/ffmpeg-gpu-test

# 3. Setup çalıştır
chmod +x setup-runpod-l40s.sh
./setup-runpod-l40s.sh

# 4. Test kaynakları oluştur
chmod +x generate-test-sources.sh
./generate-test-sources.sh

# 5. Kamera URL'lerini ekle (opsiyonel)
cp your-cameras.txt cameras_test.txt

# 6. GPU testini başlat
chmod +x ultimate-gpu-test.sh
./ultimate-gpu-test.sh

# 7. Monitoring (ayrı terminal)
./monitor-gpu.sh
```

## GPU Optimizasyonları

### FFmpeg Komut Karşılaştırması

**CPU (Original):**
```bash
ffmpeg -i rtsp://camera \
  -vf scale=1280:720 \
  -c:v libx264 -crf 36 -preset medium \
  -f hls output.m3u8
```

**GPU (Optimized):**
```bash
ffmpeg -hwaccel cuda -hwaccel_output_format cuda \
  -i rtsp://camera \
  -vf scale_cuda=1280:720 \
  -c:v h264_nvenc -preset p4 -cq 36 \
  -f hls output.m3u8
```

### Kritik Parametreler
- **-hwaccel cuda**: GPU decode acceleration
- **scale_cuda**: GPU-based scaling
- **h264_nvenc**: NVIDIA hardware encoder
- **-cq 36**: Constant quality (CRF equivalent)
- **-preset p4**: Balance between speed/quality

## L40S GPU Özellikleri
- **VRAM**: 48GB GDDR6
- **NVENC**: Unlimited sessions (professional GPU)
- **Performance**: 200+ concurrent 720p streams capability
- **Power**: More efficient than CPU encoding

## Monitoring Metrikleri

Test sırasında toplanan metrikler:
- GPU Utilization (%)
- VRAM Usage (MB)
- NVENC Session Count
- CPU Usage (%)
- Stream Success Rate
- Average FPS
- Output Bitrate

## Beklenen Sonuçlar

| Concurrent Streams | GPU Usage | VRAM | CPU | Success Rate |
|-------------------|-----------|------|-----|--------------|
| 10                | ~5%       | 2GB  | 5%  | 100%         |
| 50                | ~25%      | 8GB  | 10% | 100%         |
| 100               | ~50%      | 15GB | 15% | 100%         |
| 150               | ~75%      | 22GB | 20% | 95%+         |
| 200               | ~90%      | 30GB | 25% | 90%+         |

## Troubleshooting

### FFmpeg NVENC bulunamazsa
```bash
# Check support
ffmpeg -hide_banner -encoders | grep nvenc

# Rebuild if needed
apt-get install ffmpeg  # or build from source
```

### GPU görünmüyorsa
```bash
# Check driver
nvidia-smi

# Install if needed
apt-get install nvidia-driver-535
reboot
```

### Memory issues
```bash
# Monitor VRAM
watch -n 1 nvidia-smi

# Reduce quality if needed
-cq 40  # instead of 36
```

## Production Önerileri

1. **Optimal Stream Count**: Test sonuçlarına göre belirle (muhtemelen 100-150)
2. **Load Balancing**: Multiple GPU instances için round-robin
3. **Failover**: Stream failure durumunda automatic restart
4. **Monitoring**: Prometheus + Grafana for real-time metrics
5. **Scaling**: Kubernetes with GPU nodes for auto-scaling