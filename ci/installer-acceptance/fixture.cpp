#include "../../src/core.hpp"

#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <sstream>
#include <string>
#include <vector>

using namespace eye;
namespace fs = std::filesystem;

static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

static std::string readFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("read failed: " + path.string());
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

static void writeFile(const fs::path& path, const std::string& value) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("create failed: " + path.string());
    out.write(value.data(), static_cast<std::streamsize>(value.size()));
    if (!out) throw std::runtime_error("write failed: " + path.string());
}

static Settings representativeSettings() {
    Settings s;
    s.workMinutes = 25;
    s.breakSeconds = 30;
    s.sound = 2;
    s.volume = 63;
    s.mode = 1;
    s.monitor = 0;
    s.theme = 2;
    s.alarm = true;
    s.repeat = true;
    s.notifications = false;
    s.snooze = true;
    s.autoStart = true;
    s.startup = false;
    s.tray = false;
    s.restore = true;
    s.pauseLocked = true;
    s.history = true;
    s.trayExplained = false;
    s.width = 820;
    s.height = 720;
    s.x = -32000;
    s.y = -32000;
    s.selectedMonitor.clear();
    s.schedule.enabled = false;
    return s;
}

static std::string legacySettings(const Settings& s) {
    std::ostringstream out;
#define EYE_WRITE(field) out << #field << '=' << s.field << '\n'
    EYE_WRITE(workMinutes); EYE_WRITE(breakSeconds); EYE_WRITE(sound); EYE_WRITE(volume); EYE_WRITE(mode); EYE_WRITE(monitor); EYE_WRITE(theme);
    EYE_WRITE(alarm); EYE_WRITE(repeat); EYE_WRITE(notifications); EYE_WRITE(snooze); EYE_WRITE(autoStart); EYE_WRITE(startup); EYE_WRITE(tray);
    EYE_WRITE(restore); EYE_WRITE(pauseLocked); EYE_WRITE(history); EYE_WRITE(trayExplained); EYE_WRITE(width); EYE_WRITE(height); EYE_WRITE(x); EYE_WRITE(y); EYE_WRITE(selectedMonitor);
#undef EYE_WRITE
    return out.str();
}
static std::int64_t nowUtc() {
    return static_cast<std::int64_t>(std::time(nullptr));
}

static void writeRepresentative(const fs::path& dir) {
    fs::create_directories(dir);
    const std::int64_t now = nowUtc();
    const Settings settings = representativeSettings();
    Saved timer;
    timer.phase = static_cast<int>(Phase::Work);
    timer.paused = false;
    timer.remaining = 1190;
    timer.duration = 1500;
    timer.cycle = 41;
    timer.at = now;
    const std::vector<Record> history{
        {now - 86400, true, 20},
        {now - 43200, false, 7}
    };
    writeFile(dir / "settings.ini", legacySettings(settings));
    writeFile(dir / "timer.dat", encodeTimer(timer));
    writeFile(dir / "history.dat", encodeHistory(history));
    writeFile(dir / "acceptance-unrelated-sentinel.txt", "EYE-BREAK-ACCEPTANCE-SENTINEL-v1\nseeded-at=" + std::to_string(now) + "\n");
}

static void writeStaleTimer(const fs::path& dir) {
    fs::create_directories(dir);
    Saved timer;
    timer.phase = static_cast<int>(Phase::Work);
    timer.paused = false;
    timer.remaining = 100;
    timer.duration = 1200;
    timer.cycle = 999;
    timer.at = nowUtc();
    writeFile(dir / "timer.dat", encodeTimer(timer));
}

static void writeScheduleHold(const fs::path& dir) {
    Settings settings;
    require(decodeSettings(readFile(dir / "settings.ini"), settings), "existing settings must decode before schedule probe");
    settings.schedule.enabled = true;
    settings.schedule.days.fill(false);
    settings.schedule.counts.fill(1);
    Saved timer;
    timer.phase = static_cast<int>(Phase::Work);
    timer.paused = false;
    timer.remaining = 300;
    timer.duration = settings.workMinutes * 60;
    timer.cycle = 42;
    timer.at = nowUtc();
    writeFile(dir / "settings.ini", encodeSettings(settings));
    writeFile(dir / "timer.dat", encodeTimer(timer));
}

static std::int64_t seededAt(const fs::path& dir) {
    const std::string sentinel = readFile(dir / "acceptance-unrelated-sentinel.txt");
    const std::string key = "seeded-at=";
    const auto pos = sentinel.find(key);
    require(pos != std::string::npos, "sentinel must carry the fixture timestamp");
    std::size_t used = 0;
    const auto value = std::stoll(sentinel.substr(pos + key.size()), &used);
    require(used > 0, "sentinel timestamp must be numeric");
    return value;
}

static std::vector<Record> validatedHistory(const fs::path& dir, std::int64_t seed) {
    std::vector<Record> history;
    require(decodeHistory(readFile(dir / "history.dat"), history, nowUtc()), "history must decode");
    require(history.size() == 2, "two fixture history records must remain");
    require(history[0].at == seed - 86400 && history[0].completed && history[0].seconds == 20, "first fixture history record must remain byte-semantically unchanged");
    require(history[1].at == seed - 43200 && !history[1].completed && history[1].seconds == 7, "second fixture history record must remain byte-semantically unchanged");
    return history;
}

static void validateDefaultSchedule(const Settings& settings) {
    require(!settings.schedule.enabled, "default schedule must be off");
    for (int day = 0; day < 7; ++day) {
        require(settings.schedule.days[day] == (day < 5), "default schedule must select Monday through Friday only");
        require(settings.schedule.counts[day] == 1, "default schedule must contain one period per day");
        require(settings.schedule.periods[day][0] == Period{540, 1020}, "default schedule hours must be 09:00 to 17:00");
    }
}

static void validate(const fs::path& dir, const std::string& mode, std::int64_t freshAnchor = 0) {
    Settings settings;
    require(decodeSettings(readFile(dir / "settings.ini"), settings), "settings must decode");
    Saved timer;
    require(decodeTimer(readFile(dir / "timer.dat"), timer), "timer must decode");
    if (mode == "representative") {
        (void)validatedHistory(dir, seededAt(dir));
        require(settings.workMinutes == 25 && settings.breakSeconds == 30, "representative intervals must persist");
        require(settings.sound == 2 && settings.volume == 63 && settings.theme == 2 && settings.mode == 1 && settings.monitor == 0, "representative sound, volume, theme, mode and monitor preferences must persist");
        require(settings.alarm && settings.repeat && !settings.notifications && settings.snooze, "representative alarm, repeat, notification and snooze settings must persist");
        require(settings.autoStart && !settings.startup && !settings.tray && settings.restore && settings.pauseLocked && settings.history && !settings.trayExplained, "representative behavior settings must persist");
        require(settings.selectedMonitor.empty(), "representative selected monitor must remain empty");
        validateDefaultSchedule(settings);
        require(timer.phase == static_cast<int>(Phase::Work) && !timer.paused, "running work timer must persist");
        require(timer.duration == 1500 && timer.remaining == 1190 && timer.cycle == 41, "fixture timer must retain its exact seeded checkpoint");
        require(readFile(dir / "settings.ini").find("schedule=") == std::string::npos, "v1.0.6 fixture must omit all schedule keys");
    } else if (mode == "resumed") {
        const std::int64_t seed = seededAt(dir);
        (void)validatedHistory(dir, seed);
        require(settings.workMinutes == 25 && settings.breakSeconds == 30, "legacy intervals must load in the application");
        require(settings.sound == 2 && settings.volume == 63 && settings.theme == 2 && settings.mode == 1 && settings.monitor == 0, "legacy sound, volume, theme, mode and monitor preferences must load in the application");
        require(settings.alarm && settings.repeat && !settings.notifications && settings.snooze, "legacy alarm, repeat, notification and snooze settings must load in the application");
        require(settings.autoStart && !settings.startup && !settings.tray && settings.restore && settings.pauseLocked && settings.history && !settings.trayExplained, "legacy behavior settings must load in the application");
        require(settings.selectedMonitor.empty(), "legacy selected monitor must remain empty");
        validateDefaultSchedule(settings);
        require(timer.phase == static_cast<int>(Phase::Work) && !timer.paused, "application must resume the seeded running work timer");
        require(timer.duration == 1500 && timer.cycle == 41, "application must preserve the seeded timer duration and cycle");
        const std::int64_t elapsed = nowUtc() - seed;
        require(elapsed >= 0 && elapsed < 1190, "fixture timer must remain within its original work interval");
        require(std::abs(timer.remaining - (1190.0 - static_cast<double>(elapsed))) <= 5.0, "resumed timer must match the seeded checkpoint minus elapsed wall time");
    } else if (mode == "schedule-input") {
        (void)validatedHistory(dir, seededAt(dir));
        require(settings.workMinutes == 25 && settings.schedule.enabled, "schedule input must be enabled");
        for (bool selected : settings.schedule.days) require(!selected, "schedule input must have no enabled days");
        require(timer.phase == static_cast<int>(Phase::Work) && !timer.paused, "schedule input timer must be running work");
        require(timer.duration == 1500 && timer.remaining == 300, "schedule input must start with the short remaining timer");
    } else if (mode == "schedule-hold") {
        (void)validatedHistory(dir, seededAt(dir));
        require(settings.workMinutes == 25 && settings.schedule.enabled, "candidate schedule must be enabled");
        for (bool selected : settings.schedule.days) require(!selected, "closed schedule fixture must have no enabled days");
        require(timer.phase == static_cast<int>(Phase::Work) && !timer.paused, "held timer must remain unpaused work");
        require(timer.duration == 1500 && timer.remaining == 1500, "closed schedule must restart a fresh full work interval");
    } else if (mode == "fresh") {
        if (fs::exists(dir / "history.dat")) {
            std::vector<Record> history;
            require(decodeHistory(readFile(dir / "history.dat"), history, nowUtc()), "fresh history, if created, must decode");
            require(history.empty(), "fresh installation must not create unrelated history records");
        }
        require(settings.workMinutes == 20 && settings.breakSeconds == 20 && settings.restore, "fresh default settings must persist");
        validateDefaultSchedule(settings);
        require(timer.phase == static_cast<int>(Phase::Work) && !timer.paused, "fresh timer must be running work");
        require(timer.duration == 1200, "fresh timer duration must be 20 minutes");
        require(freshAnchor > 0 && timer.at >= freshAnchor, "fresh timer checkpoint must follow the recorded first launch");
        const std::int64_t elapsed = timer.at - freshAnchor;
        require(elapsed >= 0 && elapsed < 1200, "fresh timer must remain within its first work cycle");
        require(std::abs(timer.remaining - (1200.0 - static_cast<double>(elapsed))) <= 5.0, "fresh timer checkpoint must match the 20-minute launch minus elapsed time");
        require(timer.cycle == 1, "fresh installation must not restore a stale timer checkpoint");
    } else {
        throw std::runtime_error("unknown validation mode");
    }
}

static void schedulePolicyCheck() {
    Settings settings;
    settings.autoStart = true;
    settings.workMinutes = 25;
    settings.schedule.enabled = true;
    settings.schedule.days.fill(false);
    settings.schedule.days[0] = true;
    settings.schedule.counts[0] = 1;
    settings.schedule.periods[0][0] = Period{540, 1020};

    std::int64_t wall = daysFromCivil(2025, 1, 6) * 86400 + 8 * 3600 + 59 * 60;
    double monotonic = 0;
    Engine engine(settings, [&] { return monotonic; }, [&] { return wall; }, utcCalendar);
    require(engine.snapshot().held, "schedule must hold before Monday 09:00");
    require(engine.snapshot().remaining == 1500, "closed schedule starts at full duration");

    monotonic += 60;
    wall += 60;
    engine.tick();
    require(!engine.snapshot().held, "schedule must release at Monday 09:00");
    require(engine.snapshot().remaining == 1500, "schedule opening starts a fresh interval");

    monotonic += 8 * 3600;
    wall += 8 * 3600;
    engine.tick();
    require(engine.snapshot().held, "schedule must hold again at Monday 17:00");
    require(engine.snapshot().remaining == 1500, "schedule closing must not consume work time");
}

int main(int argc, char** argv) {
    try {
        require(argc >= 2, "usage: fixture.exe seed|schedule-core|validate ...");
        const std::string command = argv[1];
        if (command == "seed") {
            require(argc == 4, "usage: fixture.exe seed representative|schedule-hold|stale-timer <data-dir>");
            const std::string mode = argv[2];
            if (mode == "representative") writeRepresentative(argv[3]);
            else if (mode == "schedule-hold") writeScheduleHold(argv[3]);
            else if (mode == "stale-timer") writeStaleTimer(argv[3]);
            else throw std::runtime_error("unknown seed mode");
            std::cout << "{\"status\":\"PASS\",\"operation\":\"seed\",\"mode\":\"" << mode << "\"}\n";
        } else if (command == "validate") {
            const std::string mode = argc >= 3 ? argv[2] : "";
            require(argc == 4 || (mode == "fresh" && argc == 5), "usage: fixture.exe validate representative|schedule-hold <data-dir> | fresh <data-dir> <first-launch-epoch>");
            const std::int64_t freshAnchor = argc == 5 ? std::stoll(argv[4]) : 0;
            validate(argv[3], mode, freshAnchor);
            std::cout << "{\"status\":\"PASS\",\"operation\":\"validate\",\"mode\":\"" << argv[2] << "\"}\n";
        } else if (command == "schedule-core") {
            schedulePolicyCheck();
            std::cout << "{\"status\":\"PASS\",\"operation\":\"schedule-core\"}\n";
        } else {
            throw std::runtime_error("unknown command");
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
