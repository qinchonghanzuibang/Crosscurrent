// Xcode 26 expects an object product for NumKong's header-only CNumKong target.
// SwiftPM CLI correctly treats it as header-only; this empty translation unit satisfies Xcode's linker input.
void feedflow_cnumkong_xcode_header_only_shim(void) {}
