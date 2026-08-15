// CLI harness for interoperability testing between C++ core and Python library.
// Usage:
//   bwm_cli embed_text <in> <text> <pw_wm> <pw_img> <out.png>
//   bwm_cli embed_img  <in> <wm_img> <pw_wm> <pw_img> <out.png>
//   bwm_cli embed_bits <in> <bitstr01> <pw_wm> <pw_img> <out.png>
//   bwm_cli extract_text <in> <wm_length> <pw_wm> <pw_img>
//   bwm_cli extract_img  <in> <h> <w> <pw_wm> <pw_img> <out.png>
//   bwm_cli extract_bits <in> <wm_length> <pw_wm> <pw_img>
//   bwm_cli wm_size_text <text>
//   bwm_cli wm_size_img  <imgfile>
#include "watermark_core.hpp"
#include "image_io.hpp"
#include <iostream>
#include <string>
#include <cstdlib>

using namespace bwm;

static int parseMode(const std::string& s) {
    return s == "text" ? 0 : (s == "img" ? 1 : 2);
}

int main(int argc, char** argv) {
    if (argc < 2) return 1;
    std::string cmd = argv[1];

    if (cmd == "wm_size_text" && argc >= 3) {
        BlindWatermarkCore core;
        core.setWatermarkText(argv[2]);
        std::cout << core.getWatermarkSize() << std::endl;
        return 0;
    }
    if (cmd == "wm_size_img" && argc >= 3) {
        Image wm;
        if (!loadGrayscaleImage(argv[2], wm)) return 2;
        BlindWatermarkCore core;
        core.setWatermarkImage(wm);
        std::cout << core.getWatermarkSize() << std::endl;
        return 0;
    }
    if (cmd == "embed_text" && argc >= 7) {
        Image img;
        if (!loadImage(argv[2], img)) { std::cerr << "load fail\n"; return 2; }
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        core.setImage(img);
        core.setWatermarkText(argv[3]);
        Image out = core.embed();
        if (!saveImage(argv[6], out)) { std::cerr << "save fail\n"; return 3; }
        std::cout << "embedded wm_size=" << core.getWatermarkSize() << std::endl;
        return 0;
    }
    if (cmd == "embed_img" && argc >= 7) {
        Image img, wm;
        if (!loadImage(argv[2], img)) return 2;
        if (!loadGrayscaleImage(argv[3], wm)) return 2;
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        core.setImage(img);
        core.setWatermarkImage(wm);
        Image out = core.embed();
        if (!saveImage(argv[6], out)) return 3;
        std::cout << "embedded wm_size=" << core.getWatermarkSize() << std::endl;
        return 0;
    }
    if (cmd == "embed_bits" && argc >= 7) {
        Image img;
        if (!loadImage(argv[2], img)) return 2;
        std::string bs = argv[3];
        std::vector<uint8_t> bits;
        for (char c : bs) bits.push_back(c == '1' ? 1 : 0);
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        core.setImage(img);
        core.setWatermarkBits(bits);
        Image out = core.embed();
        if (!saveImage(argv[6], out)) return 3;
        std::cout << "embedded wm_size=" << core.getWatermarkSize() << std::endl;
        return 0;
    }
    if (cmd == "extract_raw" && argc >= 6) {
        Image img;
        if (!loadImage(argv[2], img)) return 2;
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        std::vector<double> avg = core.extractRaw(img, static_cast<size_t>(std::atoll(argv[3])));
        for (double v : avg) std::printf("%.6f ", v);
        std::cout << std::endl;
        return 0;
    }
    if (cmd == "extract_text" && argc >= 6) {
        Image img;
        if (!loadImage(argv[2], img)) return 2;
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        std::string text = core.extractText(img, static_cast<size_t>(std::atoll(argv[3])));
        std::cout << text << std::endl;
        return 0;
    }
    if (cmd == "extract_img" && argc >= 8) {
        Image img;
        if (!loadImage(argv[2], img)) return 2;
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[5]);
        cfg.passwordImg = std::atoi(argv[6]);
        BlindWatermarkCore core(cfg);
        Image out = core.extractImage(img, std::atoi(argv[3]), std::atoi(argv[4]));
        if (!saveImage(argv[7], out)) return 3;
        std::cout << "extracted" << std::endl;
        return 0;
    }
    if (cmd == "extract_bits" && argc >= 6) {
        Image img;
        if (!loadImage(argv[2], img)) return 2;
        WatermarkConfig cfg;
        cfg.passwordWm = std::atoi(argv[4]);
        cfg.passwordImg = std::atoi(argv[5]);
        BlindWatermarkCore core(cfg);
        std::vector<uint8_t> bits = core.extractBits(img, static_cast<size_t>(std::atoll(argv[3])));
        for (uint8_t b : bits) std::cout << (b ? '1' : '0');
        std::cout << std::endl;
        return 0;
    }
    return 1;
}
