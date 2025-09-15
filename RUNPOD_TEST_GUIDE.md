# RunPod GPU Test Rehberi - Adım Adım

## 🚀 Hızlı Başlangıç

Bu rehber, RunPod'da L40S GPU ile FFmpeg concurrent transcoding testlerini nasıl çalıştıracağını adım adım anlatır.

---

## 📋 Adım 1: RunPod Instance Oluştur

1. [RunPod.io](https://runpod.io) hesabına giriş yap
2. **Deploy** → **GPU Cloud** seç
3. GPU seç: **L40S** (48GB VRAM)
4. Template: **RunPod Pytorch** veya **Ubuntu 22.04**
5. Disk: Minimum **100GB** (test dosyaları için)
6. **Deploy On-Demand** tıkla

---

## 🔧 Adım 2: Instance'a Bağlan

```bash
# RunPod web terminal veya SSH kullan
# SSH için:
ssh root@[your-instance-ip] -p [port]
```

---

## 📦 Adım 3: Repo'yu Clone Et

```bash
# Ana dizine geç
cd /workspace

# Repo'yu clone et
git clone https://github.com/aktasberkin/ffmpeg-gpu-test.git
cd ffmpeg-gpu-test

# Script'leri executable yap
chmod +x *.sh
```

---

## ⚙️ Adım 4: Sistemi Hazırla

```bash
# Setup script'ini çalıştır
./setup-runpod-l40s.sh

# Bu script otomatik olarak:
# - NVIDIA driver kontrol eder
# - FFmpeg NVENC support kurar
# - Monitoring tools yükler
# - System limits ayarlar
```

### Setup sonrası kontrol:
```bash
# GPU kontrolü
nvidia-smi

# FFmpeg NVENC kontrolü
ffmpeg -encoders | grep nvenc
# h264_nvenc görmelisin
```

---

## 🎬 Adım 5: Test Kaynakları Oluştur

```bash
# Synthetic test videoları oluştur (network bağımsız)
./generate-test-sources.sh

# Bu script:
# - Test pattern'leri oluşturur
# - Sample videolar indirir (opsiyonel)
# - 200+ test kaynağı hazırlar
```

---

## 🏃 Adım 6: Ana Testi Çalıştır

### Önerilen: Detailed Concurrent Test

```bash
# En kapsamlı test (gerçek HLS dosya çıktıları ile)
./detailed-concurrent-test.sh

# Test sırasında başka bir terminal'de monitoring:
./monitor-helper.sh live gpu_test_[timestamp]
```

### Test Seviyeleri:
- Başlar: 5 concurrent streams
- Artar: 10, 20, 50, 100, 150, 200
- Her seviyeden sonra devam etmek ister

### Test Çıktıları:
```
gpu_test_20250115_143022/
├── streams/         # HLS dosyaları (m3u8 + ts)
├── logs/           # FFmpeg logları
└── reports/        # Metrikler ve raporlar
    ├── live_metrics.txt       # Canlı takip
    ├── detailed_metrics.csv   # Tüm data
    └── test_summary.txt       # Özet
```

---

## 📊 Adım 7: Real-time Monitoring

### Terminal 1: Test çalıştır
```bash
./detailed-concurrent-test.sh
```

### Terminal 2: GPU monitoring
```bash
# Sadece GPU
./monitor-helper.sh gpu

# veya nvidia-smi
watch -n 1 nvidia-smi
```

### Terminal 3: Live metrics
```bash
# Test metriklerini canlı izle
./monitor-helper.sh live gpu_test_20250115_143022

# veya
tail -f gpu_test_20250115_143022/reports/live_metrics.txt
```

### Terminal 4: Disk monitoring
```bash
# Disk kullanımını izle
./monitor-helper.sh disk gpu_test_20250115_143022
```

---

## 🔍 Adım 8: Sonuçları Kontrol Et

### Quick summary:
```bash
./monitor-helper.sh summary gpu_test_20250115_143022
```

### Detaylı analiz:
```bash
./analyze-results.sh gpu_test_20250115_143022

# Göreceğin metrikler:
# - Peak ve Average GPU/VRAM/CPU kullanımı
# - Timeline analizi
# - Optimal stream sayısı önerisi
```

### Manuel dosya kontrolü:
```bash
# HLS dosyalarını kontrol et
ls -la gpu_test_20250115_143022/streams/stream_0001/

# Playlist'i incele
cat gpu_test_20250115_143022/streams/stream_0001/playlist.m3u8

# Video segment'i test et (ffprobe yüklüyse)
ffprobe gpu_test_20250115_143022/streams/stream_0001/segment_00001.ts

# Toplam dosya sayısı
find gpu_test_20250115_143022/streams -name "*.ts" | wc -l
```

---

## 📈 Adım 9: Sonuçları İndir

```bash
# Özet raporu görüntüle
cat gpu_test_20250115_143022/reports/test_summary.txt

# CSV'yi lokal bilgisayara indir (analiz için)
# RunPod File Browser kullan veya:
scp -P [port] root@[ip]:/workspace/ffmpeg-gpu-test/gpu_test_*/reports/*.csv .
```

---

## 🎯 Beklenen Sonuçlar

### L40S GPU ile:
- **100-150 concurrent streams**: Stabil
- **GPU Utilization**: %80-90 average
- **VRAM**: 15-20GB kullanım
- **CPU**: %20-30 (GPU sayesinde düşük)
- **NVENC Sessions**: Limit yok (professional GPU)

---

## ⚠️ Önemli Notlar

1. **Test süresi**: Her seviye 60 saniye, toplam ~15-20 dakika
2. **Disk alanı**: 200 stream testi ~30-50GB yer kaplar
3. **Cleanup**: Test bitince eski dosyaları sil:
   ```bash
   rm -rf gpu_test_2025*
   ```

4. **Cost optimization**: Test bitince instance'ı **durdur**!

---

## 🆘 Sorun Giderme

### FFmpeg NVENC bulunamazsa:
```bash
# Manuel kurulum
apt update
apt install ffmpeg
# veya setup script'ini tekrar çalıştır
./setup-runpod-l40s.sh
```

### GPU görünmüyorsa:
```bash
# Driver kontrolü
nvidia-smi
# Driver yükleme gerekebilir
apt install nvidia-driver-535
reboot
```

### Disk doluyorsa:
```bash
# Eski test dosyalarını temizle
rm -rf gpu_test_*/streams/
# Sadece raporları koru
```

---

## 📝 Test Sonuç Örneği

```
Performance Metrics:
- GPU Utilization: Peak 94% | Average 78.3%
- VRAM Usage: Peak 18456MB | Average 15234MB
- NVENC Sessions: Peak 187 | Average 156.8
- CPU Usage: Peak 28% | Average 19.2%

Recommended concurrent streams: 175
Success rate: 95%
```

---

## ✅ Başarılı Test Kriterleri

1. **GPU Utilization > %70**: GPU verimli kullanılıyor
2. **Success rate > %90**: Stream'ler başarılı
3. **CPU < %30**: GPU offloading çalışıyor
4. **HLS dosyaları oluşuyor**: playlist.m3u8 + segment.ts

---

## 🔄 Farklı Test Alternatifleri

```bash
# Daha agresif test (true concurrent)
./true-concurrent-test.sh

# Robust test (batch processing)
./robust-gpu-test.sh

# Process pool yaklaşımı
./process-pool-test.sh
```

---

## 📞 Destek

Sorun yaşarsan:
1. FFmpeg loglarını kontrol et: `logs/` dizini
2. GPU durumunu kontrol et: `nvidia-smi`
3. Script output'larını kaydet
4. GitHub Issues'da paylaş

---

**İyi testler! 🚀 GPU gücünü keşfet!**