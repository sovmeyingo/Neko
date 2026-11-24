#include "Utils/Update/AppUpdater.h"
#include "Utils/SteamMetadata/Mirror.h"
#include "OSTPlatform/include/DynamicLibrary.h"
#include "OSTPlatform/include/Hash.h"
#include "OSTPlatform/include/Process.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace {
std::string pointerBody;
std::string downloadedDll;

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

std::string Read(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    Require(file.good(), "Could not open test fixture");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

std::string Pointer(const std::string& hash) {
    return "product = \"Neko\"\nformat = 1\nversion = \"test-new\"\n"
           "path = \"neko/test-new/Neko.dll\"\nsha256 = \"" + hash + "\"\n";
}
}

// Only the HTTP transport is replaced. Parsing, hashing and staging use production code.
namespace Mirror {
std::optional<std::string> Fetch(std::string_view path) {
    if (path == "neko/latest.toml") return pointerBody;
    if (path == "neko/test-new/Neko.dll") return downloadedDll;
    return std::nullopt;
}
}

namespace OSTPlatform::DynamicLibrary {
std::filesystem::path GetMainExecutablePath() {
    throw std::runtime_error("Test attempted to restart Steam");
}
}

namespace OSTPlatform::Process {
bool LaunchDetachedHidden(const std::string&) {
    throw std::runtime_error("Test attempted to start a process");
}
}

int main(int argc, char** argv) {
    try {
        Require(argc == 3, "Expected Neko.dll and an empty test directory");
        const std::filesystem::path sandbox = std::filesystem::absolute(argv[2]);
        Require(!std::filesystem::exists(sandbox), "Test directory already exists");
        std::filesystem::create_directories(sandbox);
        const auto self = sandbox / "Neko.dll";
        std::filesystem::copy_file(argv[1], self);
        const std::string original = Read(self);
        const std::string originalHash = OSTPlatform::Hash::Sha256OfFile(self);

        pointerBody = "version=\"upstream\"\npath=\"opensteamtool/upstream/OpenSteamTool.dll\"\nsha256=\"abc\"\n";
        Require(!AppUpdater::Check().updateAvailable, "Accepted an upstream update pointer");
        pointerBody = Pointer(originalHash);
        auto update = AppUpdater::Check();
        Require(update.updateAvailable && update.dllRelPath == "neko/test-new/Neko.dll",
                "Rejected a valid Neko update pointer");

        pointerBody.replace(pointerBody.find("neko/test-new/Neko.dll"), 22,
                            "neko/../other/Neko.dll");
        Require(!AppUpdater::Check().updateAvailable, "Accepted a traversal path");

        downloadedDll = original;
        auto wrongHash = update;
        wrongHash.sha256 = std::string(64, '0');
        Require(!AppUpdater::DownloadAndStage(wrongHash, self.string()), "Accepted a wrong SHA-256");
        Require(Read(self) == original, "A rejected update changed the current DLL");

        const std::string identity = "Neko.Update.Format.1";
        auto identityOffset = downloadedDll.find(identity);
        Require(identityOffset != std::string::npos, "Built DLL has no Neko identity");
        while (identityOffset != std::string::npos) {
            downloadedDll.replace(identityOffset, identity.size(), std::string(identity.size(), 'X'));
            identityOffset = downloadedDll.find(identity);
        }
        auto unbranded = update;
        unbranded.sha256 = OSTPlatform::Hash::Sha256OfBuffer(downloadedDll.data(), downloadedDll.size());
        Require(!AppUpdater::DownloadAndStage(unbranded, self.string()),
                "Accepted a correctly hashed DLL without Neko identity");
        Require(Read(self) == original, "Unbranded update changed the current DLL");

        downloadedDll = original;
        downloadedDll[0] = 'X';
        auto malformed = update;
        malformed.sha256 = OSTPlatform::Hash::Sha256OfBuffer(downloadedDll.data(), downloadedDll.size());
        Require(!AppUpdater::DownloadAndStage(malformed, self.string()), "Accepted a malformed PE");

        downloadedDll = original;
        Require(AppUpdater::DownloadAndStage(update, self.string()), "Could not stage a valid Neko DLL");
        Require(Read(self) == original && Read(self.string() + ".old") == original,
                "Staging did not preserve both DLLs");
        AppUpdater::CleanupStagedBackup(self.string());
        Require(!std::filesystem::exists(self.string() + ".old"), "Backup cleanup failed");
        std::cout << "PASS: Neko update parsing, legacy rejection, hash, identity, PE, staging and backup cleanup\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
