#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <coreml_provider_factory.h>
#include <onnxruntime_cxx_api.h>

namespace {
thread_local std::string last_error;

struct Handle {
  Ort::Env environment{ORT_LOGGING_LEVEL_WARNING, "crosscurrent-qualification"};
  Ort::Session session{nullptr};
  std::vector<std::string> input_names;
  std::string output_name;
  size_t dimensions = 0;

  Handle(const char* model_path, bool coreml, size_t expected_dimensions) {
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    options.SetIntraOpNumThreads(1);
    if (coreml) {
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(
          options, COREML_FLAG_CREATE_MLPROGRAM));
    }
    session = Ort::Session(environment, model_path, options);
    Ort::AllocatorWithDefaultOptions allocator;
    for (size_t index = 0; index < session.GetInputCount(); ++index) {
      auto name = session.GetInputNameAllocated(index, allocator);
      input_names.emplace_back(name.get());
    }
    for (size_t index = 0; index < session.GetOutputCount(); ++index) {
      auto name = session.GetOutputNameAllocated(index, allocator);
      std::string value(name.get());
      if (output_name.empty() || value == "sentence_embedding" ||
          value == "last_hidden_state") {
        output_name = std::move(value);
        if (output_name == "sentence_embedding") break;
      }
    }
    if (output_name.empty()) throw std::runtime_error("ONNX model has no output");
    dimensions = expected_dimensions;
  }
};

int fail(const std::exception& error) {
  last_error = error.what();
  return 0;
}

void normalize(float* vector, size_t dimensions) {
  double sum = 0;
  for (size_t index = 0; index < dimensions; ++index) {
    sum += static_cast<double>(vector[index]) * vector[index];
  }
  const float magnitude = static_cast<float>(std::sqrt(sum));
  if (magnitude <= 0) return;
  for (size_t index = 0; index < dimensions; ++index) vector[index] /= magnitude;
}
}  // namespace

extern "C" {

const char* cc_ort_last_error() { return last_error.c_str(); }

void* cc_ort_create(const char* model_path, int use_coreml,
                    size_t expected_dimensions) {
  try {
    last_error.clear();
    return new Handle(model_path, use_coreml != 0, expected_dimensions);
  } catch (const std::exception& error) {
    fail(error);
    return nullptr;
  }
}

void cc_ort_destroy(void* opaque) { delete static_cast<Handle*>(opaque); }

int cc_ort_embed(void* opaque, const int64_t* input_ids,
                 const int64_t* attention_mask, size_t batch, size_t sequence,
                 float* output, size_t output_count) {
  try {
    last_error.clear();
    auto* handle = static_cast<Handle*>(opaque);
    if (!handle || !input_ids || !attention_mask || !output)
      throw std::runtime_error("invalid ONNX embedding arguments");
    if (output_count != batch * handle->dimensions)
      throw std::runtime_error("ONNX output buffer has the wrong size");

    const std::array<int64_t, 2> shape{static_cast<int64_t>(batch),
                                       static_cast<int64_t>(sequence)};
    const size_t element_count = batch * sequence;
    std::vector<int64_t> token_types(element_count, 0);
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto ids = Ort::Value::CreateTensor<int64_t>(
        memory, const_cast<int64_t*>(input_ids), element_count, shape.data(),
        shape.size());
    auto mask = Ort::Value::CreateTensor<int64_t>(
        memory, const_cast<int64_t*>(attention_mask), element_count, shape.data(),
        shape.size());
    auto types = Ort::Value::CreateTensor<int64_t>(
        memory, token_types.data(), element_count, shape.data(), shape.size());

    std::vector<const char*> input_names;
    std::vector<Ort::Value> input_values;
    input_names.reserve(handle->input_names.size());
    input_values.reserve(handle->input_names.size());
    for (const auto& name : handle->input_names) {
      input_names.push_back(name.c_str());
      if (name.find("attention") != std::string::npos ||
          name.find("mask") != std::string::npos) {
        input_values.emplace_back(std::move(mask));
      } else if (name.find("token_type") != std::string::npos) {
        input_values.emplace_back(std::move(types));
      } else if (name.find("input") != std::string::npos ||
                 name.find("ids") != std::string::npos) {
        input_values.emplace_back(std::move(ids));
      } else {
        throw std::runtime_error("unsupported ONNX input: " + name);
      }
    }
    const char* output_name = handle->output_name.c_str();
    auto values = handle->session.Run(Ort::RunOptions{nullptr}, input_names.data(),
                                      input_values.data(), input_values.size(),
                                      &output_name, 1);
    if (values.size() != 1 || !values[0].IsTensor())
      throw std::runtime_error("ONNX embedding output is not a tensor");
    const auto info = values[0].GetTensorTypeAndShapeInfo();
    const auto dimensions = info.GetShape();
    const float* values_data = values[0].GetTensorData<float>();
    if (dimensions.size() == 2 &&
        dimensions[0] == static_cast<int64_t>(batch) &&
        dimensions[1] == static_cast<int64_t>(handle->dimensions)) {
      std::memcpy(output, values_data, output_count * sizeof(float));
      for (size_t row = 0; row < batch; ++row)
        normalize(output + row * handle->dimensions, handle->dimensions);
      return 1;
    }
    if (dimensions.size() != 3 ||
        dimensions[0] != static_cast<int64_t>(batch) ||
        dimensions[2] != static_cast<int64_t>(handle->dimensions)) {
      throw std::runtime_error("unexpected ONNX output shape");
    }
    const size_t output_sequence = static_cast<size_t>(dimensions[1]);
    std::fill(output, output + output_count, 0.0f);
    for (size_t row = 0; row < batch; ++row) {
      size_t accepted = 0;
      for (size_t token = 0; token < std::min(sequence, output_sequence); ++token) {
        if (attention_mask[row * sequence + token] == 0) continue;
        ++accepted;
        for (size_t dimension = 0; dimension < handle->dimensions; ++dimension) {
          output[row * handle->dimensions + dimension] +=
              values_data[(row * output_sequence + token) * handle->dimensions +
                          dimension];
        }
      }
      const float divisor = static_cast<float>(std::max<size_t>(1, accepted));
      for (size_t dimension = 0; dimension < handle->dimensions; ++dimension)
        output[row * handle->dimensions + dimension] /= divisor;
      normalize(output + row * handle->dimensions, handle->dimensions);
    }
    return 1;
  } catch (const std::exception& error) {
    return fail(error);
  }
}
}
