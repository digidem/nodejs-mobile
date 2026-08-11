#include <stddef.h>
#include <stdint.h>

#include "crc.h"

// Self-contained IEEE 802.3 / zlib CRC-32 (reflected, poly 0xEDB88320, init and
// final-xor 0xFFFFFFFF). This replaces libcrc's multi-file slice-by-16
// implementation (which pulls in arch-specific intrinsics + a generated lookup
// table) with a single portable file that yields identical values — so
// crc-native's genuine N-API binding (binding.c + macros.h, vendored verbatim)
// compiles for every mobile ABI with a plain clang invocation, no CMake. The
// test cross-checks the result against Node's built-in zlib.crc32, so a wrong
// implementation here fails loudly rather than silently.
uint32_t
crc_u32 (const uint8_t *buf, size_t len) {
  static uint32_t table[256];
  static int initialized = 0;
  if (!initialized) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      }
      table[i] = c;
    }
    initialized = 1;
  }

  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++) {
    crc = table[(crc ^ buf[i]) & 0xFFu] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}
