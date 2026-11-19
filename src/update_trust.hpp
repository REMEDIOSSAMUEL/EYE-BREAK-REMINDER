#pragma once

#include <array>
#include <string_view>

namespace eye::updates {

// This release tree intentionally has no publisher key provisioned. The updater
// fails closed until the owner embeds a public key whose private half is held
// outside this repository. Never set this to a test key.
inline constexpr bool ProductionUpdateKeyProvisioned=false;
inline constexpr std::string_view ProductionUpdateKeyId="";
inline constexpr std::array<unsigned char,64> ProductionUpdatePublicKey{};

} // namespace eye::updates
