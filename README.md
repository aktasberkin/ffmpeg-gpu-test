# GPU FFmpeg Concurrent Test

RunPod üzerinde GPU-accelerated FFmpeg concurrent stream testleri için hazırlanmış script'ler.

## Dosyalar

1. **`gpu-test.sh`** - Ana test script'i (CPU test'ten modifiye edilmiş)
2. **`setup-runpod.sh`** - RunPod ortamını hazırlamak için setup script'i

## Özellikler

### Test Kaynakları
- **Public test videolar** (BigBuckBunny, ElephantsDream vb.)
- **FFmpeg synthetic sources** (testsrc2, smptebars, mandelbrot)
- **100+ concurrent stream** desteği
- Kamera dosyası gerekliliğini ortadan kaldırır

### GPU Özellikleri
- NVIDIA H.264/H.265 hardware encoding
- GPU kullanım monitoring
- NVENC session tracking
- CPU vs GPU karşılaştırması

### Test Konfigürasyonu
```bash
CONCURRENT_TESTS=(2 5 10 20 30 50 75 100 125 150)
GPU_ENCODER="h264_nvenc"  # veya hevc_nvenc
GPU_PRESET="p1"           # p1 (en hızlı) - p7 (en kaliteli)
GPU_CQ="30"              # Kalite (23-51, düşük = yüksek kalite)
```

## Kullanım

### 1. RunPod Kurulumu
```bash
# RunPod container'ında çalıştır
./setup-runpod.sh
```

### 2. Test Çalıştırma
```bash
chmod +x gpu-test.sh
./gpu-test.sh
```

### 3. Monitoring
```bash
# GPU kullanımını izle
watch -n 1 nvidia-smi

# Detaylı GPU monitoring
nvtop
```

## Beklenen Sonuçlar

### CPU vs GPU Karşılaştırması
- **CPU**: Yüksek CPU kullanımı, sınırlı concurrent stream
- **GPU**: Düşük CPU kullanımı, yüksek concurrent stream kapasitesi
- **Memory**: GPU memory kullanımı vs RAM kullanımı
- **Speed**: Encoding hızı karşılaştırması

### Ölçülen Metrikler
- GPU utilization (%)
- GPU memory usage (MB)
- NVENC encoder sessions
- CPU usage (karşılaştırma için)
- Speed ratio
- FPS performance
- Success rate

## NVENC Limitasyonları

### Session Limits
- **Consumer GPU**: Maksimum 2-3 concurrent session
- **Quadro/Tesla**: Daha yüksek session limits
- Bu limitler concurrent stream sayısını etkileyebilir

### Çözüm Önerileri
1. **Multiple GPU** kullanımı
2. **Mixed encoding** (CPU + GPU)
3. **Session pooling** stratejileri

## Sonuç Analizi

Test sonuçları `test_results/gpu_concurrent_results.csv` dosyasında saklanır:

```bash
# Sonuçları görüntüle
cat test_results/gpu_concurrent_results.csv | column -t -s,

# GPU memory kullanım grafiği için
grep -v test_id test_results/gpu_concurrent_results.csv | \
awk -F, '{print $2 "," $8}' | sort -n
```

Bu yapı ile gerçek kameralar olmadan 100+ concurrent stream testi yapabilir ve CPU vs GPU performans karşılaştırması elde edebilirsiniz.