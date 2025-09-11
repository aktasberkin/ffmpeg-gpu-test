# FFmpeg GPU Test Projesi - Durum Analizi

## Proje Özeti

### Mevcut Durum
- **Problem**: RTSP kameralardan kayıt alırken decode/encode işlemi çok fazla CPU kullanıyor
- **Hedef**: Aynı işlemi GPU üzerinden yaparak CPU yükünü azaltmak
- **Test Ortamı**: RunPod GPU kiralama servisi
- **Test Hedefi**: 100+ concurrent stream performansı

### Orijinal CPU Test Script'i
- **Dosya**: `cpu-test.sh` (Phase 2: Concurrent Testing Script)
- **Özellikler**:
  - Gerçek kamera URL'lerini `cameras_test.txt` dosyasından okur
  - 2-36 concurrent stream testi yapabilir
  - CPU tabanlı libx264 encoding kullanır
  - Detaylı performans metrikleri toplar

### CPU Script'indeki Limitasyonlar
1. **Kamera bağımlılığı**: Gerçek kamera URL'leri gerekli
2. **Sınırlı test kapasitesi**: Maksimum 36 concurrent stream
3. **CPU yoğun işlem**: libx264 encoder çok CPU kullanır
4. **GPU desteği yok**: Hardware acceleration kullanmıyor

## Geliştirilen GPU Çözümü

### Yeni Script'ler
1. **`gpu-test.sh`**: Ana GPU test script'i
2. **`setup-runpod.sh`**: RunPod ortam kurulumu
3. **`README.md`**: Kullanım rehberi
4. **`DURUM_ANALIZI.md`**: Bu dosya

### GPU Script'inin Avantajları

#### Test Kaynak Çeşitliliği
- **Public test videolar**: BigBuckBunny, ElephantsDream vb.
- **Synthetic sources**: testsrc2, smptebars, mandelbrot patterns
- **Loop desteği**: Aynı kaynak tekrar kullanılabilir
- **150+ stream desteği**: Kamera dosyası gerekliliği yok

#### GPU Hardware Acceleration
- **NVENC encoder**: h264_nvenc/hevc_nvenc
- **Preset seçenekleri**: p1 (hızlı) - p7 (kaliteli)
- **Quality control**: CQ değeri ile kalite ayarı
- **Memory efficiency**: GPU memory kullanımı

#### Monitoring ve Metrikler
- **GPU utilization**: Gerçek zamanlı GPU kullanımı
- **GPU memory**: VRAM kullanım takibi
- **NVENC sessions**: Encoder session sayısı
- **CPU karşılaştırması**: CPU vs GPU performans
- **Başarı oranları**: Stream başarı yüzdeleri

### Teknik Detaylar

#### FFmpeg Komut Karşılaştırması
```bash
# CPU (Orijinal)
ffmpeg -i "rtsp://camera" \
  -vf scale=1280:720 \
  -c:v libx264 -threads 2 -crf 35 -preset ultrafast \
  -x264-params threads=2:lookahead-threads=1 \
  -g 60 -an -f hls output.m3u8

# GPU (Yeni)
ffmpeg -i "test_source" \
  -vf scale=1280:720 \
  -c:v h264_nvenc \
  -preset p1 -tune ll -rc vbr -cq 30 \
  -b:v 2M -maxrate 3M -bufsize 4M \
  -g 60 -an -f mp4 output.mp4
```

#### Test Konfigürasyonu
- **Concurrent testler**: 2, 5, 10, 20, 30, 50, 75, 100, 125, 150 stream
- **Test süresi**: 60 saniye per test
- **Sampling interval**: 5 saniye
- **Retry mekanizması**: 3 deneme hakkı
- **Warm-up testi**: Sistem hazırlığı için

## Beklenen Sonuçlar

### Performans Metrikleri
1. **GPU utilization**: %0-100 kullanım oranı
2. **GPU memory**: VRAM kullanım miktarı (MB)
3. **NVENC sessions**: Aktif encoder session sayısı
4. **CPU usage**: Karşılaştırma için CPU kullanımı
5. **Speed ratio**: Encoding hızı (1x = real-time)
6. **FPS**: Frame per second değeri
7. **Success rate**: Başarılı stream yüzdesi

### CPU vs GPU Beklentileri
- **CPU kullanımı**: %80-90 → %10-20
- **Concurrent capacity**: 36 → 100+ streams
- **Memory usage**: RAM → VRAM
- **Power efficiency**: Daha düşük güç tüketimi
- **Heat generation**: Daha az ısı üretimi

### NVENC Limitasyonları
- **Consumer GPU**: Maksimum 2-3 concurrent session
- **Professional GPU**: Daha yüksek session limits
- **Workaround**: Multiple GPU veya mixed encoding

## İmplementasyon Stratejisi

### RunPod Kurulum Adımları
1. GPU instance oluştur (RTX 4090/A100 önerili)
2. `setup-runpod.sh` çalıştır
3. FFmpeg NVENC desteğini doğrula
4. Test script'lerini yükle
5. `gpu-test.sh` çalıştır

### Test Senaryoları
1. **Warm-up**: 1 stream ile sistem hazırlığı
2. **Scaling test**: 2→150 stream arası test
3. **Failure analysis**: Başarısız stream'lerin analizi
4. **Resource monitoring**: GPU/CPU/Memory takibi
5. **Comparison**: CPU script ile karşılaştırma

### Sonuç Analizi
- CSV format: Kolay analiz için
- Grafik oluşturma: GPU utilization vs stream count
- Optimum point: En verimli concurrent stream sayısı
- Cost analysis: GPU maliyeti vs performance gain

## Proje Durumu

### Tamamlanan İşler ✅
- [x] CPU script'i analiz edildi
- [x] GPU test script'i geliştirildi
- [x] RunPod setup script'i oluşturuldu
- [x] Test kaynak stratejisi belirlendi
- [x] Monitoring sistemi kuruldu
- [x] Dokümantasyon tamamlandı

### Yapılacak İşler 📋
- [ ] RunPod'da test ortamı kurulumu
- [ ] Script'lerin RunPod'da test edilmesi
- [ ] NVENC session limit testleri
- [ ] Multiple GPU test (gerekirse)
- [ ] Sonuç analizi ve optimizasyon
- [ ] Production implementasyonu

### Risk Faktörleri ⚠️
1. **NVENC session limits**: Consumer GPU'larda sınırlı
2. **GPU memory**: VRAM kapasitesi limitasyonu
3. **Network bandwidth**: 100+ stream için yüksek bandwidth
4. **Cost**: GPU kiralama maliyeti
5. **Compatibility**: FFmpeg NVENC desteği sorunları

## Sonraki Adımlar

1. **RunPod test**: Script'leri canlı ortamda test et
2. **Optimization**: Sonuçlara göre parametreleri ayarla
3. **Production planning**: Üretim ortamı için plan yap
4. **Cost-benefit**: Maliyet-fayda analizi yap
5. **Scaling strategy**: Büyük ölçek için strateji belirle

---

**Proje GitHub**: /Users/berkinaktas/Desktop/ffmpeg-gpu-test/
**Son güncelleme**: 2025-01-11
**Durum**: Test için hazır 🚀