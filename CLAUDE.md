# Claude Code - FFmpeg GPU Test Projesi

## Proje Hakkında

Bu proje, RTSP kameralardan concurrent stream işlemi yapan CPU-yoğun FFmpeg operasyonlarını GPU'ya taşımak için geliştirilmiştir. RunPod GPU ortamında test edilmek üzere hazırlanmış script'ler ve dokümantasyon içerir.

## Detaylı Analiz

Projenin kapsamlı durumu, teknik detayları ve implementasyon stratejisi için:
👉 **[@DURUM_ANALIZI.md](./DURUM_ANALIZI.md)** dosyasını inceleyin

## Dosya Yapısı

```
ffmpeg-gpu-test/
├── cpu-test.sh           # Orijinal CPU test script'i (referans)
├── gpu-test.sh           # Ana GPU test script'i
├── setup-runpod.sh       # RunPod ortam kurulum script'i
├── README.md             # Kullanım rehberi
├── DURUM_ANALIZI.md      # 📊 Detaylı proje analizi
└── CLAUDE.md            # Bu dosya
```

## Hızlı Başlangıç

```bash
# 1. RunPod GPU instance oluştur
# 2. Kurulum yap
./setup-runpod.sh

# 3. Test çalıştır
chmod +x gpu-test.sh
./gpu-test.sh

# 4. Sonuçları izle
watch -n 1 nvidia-smi
```

## Test Hedefleri

- **CPU → GPU**: libx264 → h264_nvenc
- **Concurrent streams**: 2 → 150+ 
- **Performance**: CPU usage %80+ → %20-
- **Scalability**: 100+ concurrent stream capacity

## Monitoring

Test sırasında GPU kullanımını izlemek için:
- `nvidia-smi` - Temel GPU metrikleri
- `nvtop` - Detaylı monitoring  
- CSV sonuçları - `test_results/gpu_concurrent_results.csv`

## Claude Code Komutları

Bu proje için yararlı Claude komutları:

```bash
# Test sonuçlarını analiz et
/analyze test_results/gpu_concurrent_results.csv

# GPU vs CPU karşılaştırması yap
/compare cpu-test.sh gpu-test.sh

# RunPod setup'ını kontrol et
/check setup-runpod.sh

# Performance optimizasyonu öner
/optimize gpu-test.sh --target=concurrent-streams
```

---

**Not**: Bu proje Claude Code ile geliştirilmiştir. Detaylı analiz ve teknik bilgiler [@DURUM_ANALIZI.md](./DURUM_ANALIZI.md) dosyasındadır.