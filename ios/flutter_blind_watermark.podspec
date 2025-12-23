Pod::Spec.new do |s|
  s.name             = 'flutter_blind_watermark'
  s.version          = '0.0.1'
  s.summary          = 'Blind watermarking library using DWT-DCT-SVD algorithm'
  s.description      = <<-DESC
Embed and extract invisible watermarks that survive compression, cropping, and other attacks.
                       DESC
  s.homepage         = 'https://github.com/example/flutter_blind_watermark'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Author' => 'author@example.com' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '12.0'

  # Swift plugin registration + C++ source files + libwebp
  s.source_files = 'Classes/**/*.swift', 'Classes/cpp/*.{cpp,hpp}',
                   'third_party/libwebp-1.3.2/src/**/*.{c,h}',
                   'third_party/libwebp-1.3.2/sharpyuv/*.{c,h}'

  # Mark C++ headers as private (not included in umbrella header)
  s.private_header_files = 'Classes/cpp/*.hpp'

  # Preserve third party headers
  s.preserve_paths = 'third_party/**/*'

  # Xcode build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Classes/cpp" "$(PODS_TARGET_SRCROOT)/third_party" "$(PODS_TARGET_SRCROOT)/third_party/Eigen" "$(PODS_TARGET_SRCROOT)/third_party/libwebp-1.3.2" "$(PODS_TARGET_SRCROOT)/third_party/libwebp-1.3.2/src"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Maximum optimization with NEON SIMD and fast math
    'OTHER_CPLUSPLUSFLAGS' => '-fvisibility=default -O3 -ffast-math -ftree-vectorize -fomit-frame-pointer',
    'OTHER_CFLAGS' => '-O3 -ffast-math -ftree-vectorize -fomit-frame-pointer',
    'GCC_OPTIMIZATION_LEVEL' => '3',
    'SWIFT_OPTIMIZATION_LEVEL' => '-O',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
    # Enable Eigen optimizations and use Apple Accelerate BLAS
    'GCC_PREPROCESSOR_DEFINITIONS' => 'BWM_HAVE_WEBP=1 EIGEN_NO_DEBUG=1 NDEBUG=1 EIGEN_USE_BLAS=1 ACCELERATE_NEW_LAPACK=1',
    # Disable Clang modules for C++ compatibility
    'CLANG_ENABLE_MODULES' => 'NO'
  }

  s.swift_version = '5.0'
  s.library = 'c++'
  s.frameworks = 'Accelerate', 'Foundation', 'UIKit'

  # Use dynamic framework to ensure FFI symbols are exported
  s.static_framework = false

  s.dependency 'Flutter'
end
