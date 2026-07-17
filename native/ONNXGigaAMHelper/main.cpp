#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "coreml_provider_factory.h"
#include "onnxruntime_cxx_api.h"

namespace {

struct WavData {
  std::vector<float> samples;
  int sample_rate = 0;
};

uint16_t read_u16(std::istream& stream) {
  uint8_t bytes[2]{};
  stream.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
  if (!stream) throw std::runtime_error("truncated WAV");
  return static_cast<uint16_t>(bytes[0] | (bytes[1] << 8));
}

uint32_t read_u32(std::istream& stream) {
  uint8_t bytes[4]{};
  stream.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
  if (!stream) throw std::runtime_error("truncated WAV");
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

std::string read_tag(std::istream& stream) {
  char value[4]{};
  stream.read(value, sizeof(value));
  if (!stream) throw std::runtime_error("truncated WAV");
  return std::string(value, sizeof(value));
}

WavData read_wav(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("cannot open WAV: " + path);
  if (read_tag(stream) != "RIFF") throw std::runtime_error("WAV is not RIFF");
  (void)read_u32(stream);
  if (read_tag(stream) != "WAVE") throw std::runtime_error("WAV is not WAVE");

  uint16_t format = 0;
  uint16_t channels = 0;
  uint16_t bits = 0;
  uint32_t sample_rate = 0;
  std::vector<uint8_t> pcm;

  while (stream && pcm.empty()) {
    const std::string tag = read_tag(stream);
    const uint32_t size = read_u32(stream);
    if (tag == "fmt ") {
      format = read_u16(stream);
      channels = read_u16(stream);
      sample_rate = read_u32(stream);
      (void)read_u32(stream);
      (void)read_u16(stream);
      bits = read_u16(stream);
      if (size < 16) throw std::runtime_error("invalid WAV fmt chunk");
      stream.seekg(size - 16, std::ios::cur);
    } else if (tag == "data") {
      pcm.resize(size);
      stream.read(reinterpret_cast<char*>(pcm.data()), size);
      if (!stream) throw std::runtime_error("truncated WAV data");
    } else {
      stream.seekg(size, std::ios::cur);
    }
    if ((size & 1U) != 0) stream.seekg(1, std::ios::cur);
  }

  if (format != 1 || channels != 1 || bits != 16 || sample_rate != 16000) {
    throw std::runtime_error("expected mono 16-bit PCM WAV at 16 kHz");
  }
  if ((pcm.size() & 1U) != 0) throw std::runtime_error("odd PCM byte count");

  WavData result;
  result.sample_rate = static_cast<int>(sample_rate);
  result.samples.resize(pcm.size() / 2);
  for (size_t index = 0; index < result.samples.size(); ++index) {
    const uint16_t raw = static_cast<uint16_t>(pcm[index * 2]) |
                         (static_cast<uint16_t>(pcm[index * 2 + 1]) << 8);
    result.samples[index] = static_cast<float>(static_cast<int16_t>(raw)) / 32768.0F;
  }
  return result;
}

std::string json_escape(const std::string& value) {
  static constexpr char hex[] = "0123456789abcdef";
  std::string result;
  result.reserve(value.size() + 16);
  for (const unsigned char byte : value) {
    switch (byte) {
      case '\\': result += "\\\\"; break;
      case '"': result += "\\\""; break;
      case '\n': result += "\\n"; break;
      case '\r': result += "\\r"; break;
      case '\t': result += "\\t"; break;
      default:
        if (byte < 0x20) {
          result += "\\u00";
          result += hex[byte >> 4];
          result += hex[byte & 0x0f];
        } else {
          result.push_back(static_cast<char>(byte));
        }
    }
  }
  return result;
}

std::vector<std::string> load_vocab(const std::string& path, int* blank_id) {
  std::ifstream stream(path);
  if (!stream) throw std::runtime_error("cannot open vocabulary: " + path);
  std::unordered_map<int, std::string> entries;
  std::string line;
  int maximum_id = -1;
  while (std::getline(stream, line)) {
    const size_t separator = line.rfind(' ');
    if (separator == std::string::npos) continue;
    const int id = std::stoi(line.substr(separator + 1));
    std::string token = line.substr(0, separator);
    if (token == "<blk>") *blank_id = id;
    entries[id] = std::move(token);
    maximum_id = std::max(maximum_id, id);
  }
  if (maximum_id < 0 || *blank_id < 0) throw std::runtime_error("invalid CTC vocabulary");
  std::vector<std::string> vocab(static_cast<size_t>(maximum_id + 1));
  for (auto& [id, token] : entries) vocab[static_cast<size_t>(id)] = std::move(token);
  return vocab;
}

void replace_all(std::string* value, const std::string& from, const std::string& to) {
  size_t position = 0;
  while ((position = value->find(from, position)) != std::string::npos) {
    value->replace(position, from.size(), to);
    position += to.size();
  }
}

std::string normalize_text(std::string value) {
  replace_all(&value, "\xE2\x96\x81", " ");  // SentencePiece word marker U+2581.
  std::string compact;
  compact.reserve(value.size());
  bool previous_space = true;
  for (const char byte : value) {
    const bool space = byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r';
    if (space) {
      if (!previous_space) compact.push_back(' ');
    } else {
      compact.push_back(byte);
    }
    previous_space = space;
  }
  while (!compact.empty() && compact.back() == ' ') compact.pop_back();
  for (const std::string punctuation : {".", ",", "!", "?", ":", ";"}) {
    replace_all(&compact, " " + punctuation, punctuation);
  }
  return compact;
}

class Recognizer {
 public:
  Recognizer(const std::string& model_path,
             const std::string& preprocessor_path,
             const std::string& vocab_path)
      : env_(make_env()),
        preprocessor_(env_, preprocessor_path.c_str(), preprocessor_options()),
        model_(env_, model_path.c_str(), model_options()),
        memory_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)),
        vocab_(load_vocab(vocab_path, &blank_id_)) {}

  std::string recognize(const std::string& wav_path) {
    WavData wav = read_wav(wav_path);
    if (wav.samples.size() < 320) return "";

    std::array<int64_t, 2> waveform_shape{1, static_cast<int64_t>(wav.samples.size())};
    std::array<int64_t, 1> length_shape{1};
    std::array<int64_t, 1> waveform_length{static_cast<int64_t>(wav.samples.size())};
    std::vector<Ort::Value> preprocessor_inputs;
    preprocessor_inputs.emplace_back(Ort::Value::CreateTensor<float>(
        memory_, wav.samples.data(), wav.samples.size(), waveform_shape.data(), waveform_shape.size()));
    preprocessor_inputs.emplace_back(Ort::Value::CreateTensor<int64_t>(
        memory_, waveform_length.data(), waveform_length.size(), length_shape.data(), length_shape.size()));

    const char* preprocessor_input_names[] = {"waveforms", "waveforms_lens"};
    const char* preprocessor_output_names[] = {"features", "features_lens"};
    auto features = preprocessor_.Run(
        Ort::RunOptions{nullptr}, preprocessor_input_names, preprocessor_inputs.data(), preprocessor_inputs.size(),
        preprocessor_output_names, 2);
    if (features.size() != 2) throw std::runtime_error("preprocessor returned unexpected outputs");

    const char* model_input_names[] = {"features", "feature_lengths"};
    const char* model_output_names[] = {"log_probs"};
    auto logits = model_.Run(Ort::RunOptions{nullptr}, model_input_names, features.data(), features.size(),
                             model_output_names, 1);
    if (logits.size() != 1) throw std::runtime_error("model returned unexpected outputs");

    const auto shape = logits[0].GetTensorTypeAndShapeInfo().GetShape();
    if (shape.size() != 3 || shape[0] != 1 || shape[2] <= 0) {
      throw std::runtime_error("unexpected log_probs shape");
    }
    const int64_t feature_length = *features[1].GetTensorData<int64_t>();
    const int64_t frame_count = std::min(shape[1], (feature_length - 1) / 4 + 1);
    const int64_t class_count = shape[2];
    if (class_count > static_cast<int64_t>(vocab_.size())) {
      throw std::runtime_error("model output exceeds vocabulary");
    }

    const float* values = logits[0].GetTensorData<float>();
    int previous = blank_id_;
    std::string text;
    for (int64_t frame = 0; frame < frame_count; ++frame) {
      const float* row = values + frame * class_count;
      int token = 0;
      for (int64_t index = 1; index < class_count; ++index) {
        if (row[index] > row[token]) token = static_cast<int>(index);
      }
      if (token != blank_id_ && token != previous) text += vocab_[static_cast<size_t>(token)];
      previous = token;
    }
    return normalize_text(std::move(text));
  }

 private:
  static Ort::Env make_env() {
    Ort::Env environment(ORT_LOGGING_LEVEL_WARNING, "guesli-onnx-gigaam");
    environment.DisableTelemetryEvents();
    return environment;
  }

  static Ort::SessionOptions preprocessor_options() {
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    options.SetIntraOpNumThreads(2);
    return options;
  }

  static Ort::SessionOptions model_options() {
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    const uint32_t flags = COREML_FLAG_ONLY_ALLOW_STATIC_INPUT_SHAPES | COREML_FLAG_USE_CPU_AND_GPU;
    Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(options, flags));
    return options;
  }

  Ort::Env env_;
  Ort::Session preprocessor_;
  Ort::Session model_;
  Ort::MemoryInfo memory_;
  int blank_id_ = -1;
  std::vector<std::string> vocab_;
};

std::string argument(int argc, char** argv, const std::string& name) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] == name) return argv[index + 1];
  }
  throw std::runtime_error("missing argument " + name);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Recognizer recognizer(argument(argc, argv, "--model"),
                          argument(argc, argv, "--preprocessor"),
                          argument(argc, argv, "--vocab"));
    std::cout << "{\"ready\":true}" << std::endl;
    std::string path;
    while (std::getline(std::cin, path)) {
      if (path.empty()) continue;
      try {
        const std::string text = recognizer.recognize(path);
        std::cout << "{\"text\":\"" << json_escape(text) << "\"}" << std::endl;
      } catch (const std::exception& error) {
        std::cout << "{\"error\":\"" << json_escape(error.what()) << "\"}" << std::endl;
      }
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "onnx-gigaam-helper: " << error.what() << std::endl;
    return 1;
  }
}
