#pragma once
#include "theme.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <map>

namespace eye {
enum class Phase { Work, Break, Snooze };
// ---- operating schedule ----------------------------------------------------------------------------------------------
// Local civil time as the OS reports it for one instant: days since 1970-01-01 in the local calendar, minute of that day and
// second of that minute. The engine never derives it from UTC itself; the Windows adapter (or a test) supplies it.
struct LocalTime {std::int64_t day=0;int minute=0,second=0;
    int weekday()const{return int(((day%7)+7+3)%7);} // 0 = Monday; 1970-01-01 was a Thursday
    std::int64_t civil()const{return day*86400+minute*60+second;}};
using LocalClock=std::function<LocalTime(std::int64_t)>;
// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil).
inline std::int64_t daysFromCivil(int y,int m,int d){y-=m<=2;std::int64_t era=(y>=0?y:y-399)/400;unsigned yoe=unsigned(y-era*400),doy=unsigned((153*(m+(m>2?-3:9))+2)/5+d-1),doe=yoe*365+yoe/4-yoe/100+doy;return era*146097+std::int64_t(doe)-719468;}
// The calendar of UTC itself: the engine's default clock and the base of the tests' synthetic time zones.
inline LocalTime utcCalendar(std::int64_t t){std::int64_t day=t>=0?t/86400:-((-t+86399)/86400),rest=t-day*86400;return{day,int(rest/60),int(rest%60)};}
// One operating period in minutes after local midnight. Start is inclusive (0..1439) and end exclusive (1..1440, where 1440 is
// 24:00). An end earlier than the start continues past midnight into the next day; the period belongs to the day it starts on.
// 00:00 to 24:00 is the explicit whole day. Equal start and end values are never valid.
struct Period {int start=540,end=1020;
    int length()const{return end>start?end-start:end+1440-start;}
    bool valid()const{return start>=0&&start<1440&&end>=1&&end<=1440&&start!=end;}
    bool operator==(const Period&o)const{return start==o.start&&end==o.end;}};
// Builds a period from clock values as typed (both 0..1440; an end of 00:00 means midnight at the end of the day). Equal values
// are rejected, so 00:00 to 00:00 is not silently read as a whole day.
inline bool makePeriod(int start,int end,Period&out){if(start<0||start>=1440||end<0||end>1440||start==end)return false;out=Period{start,end==0?1440:end};return true;}
inline constexpr const char* scheduleDayNames[7]={"Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"};
// The weekly operating schedule. Days are Monday (0) to Sunday (6); each day keeps one to three periods, so its hours are
// remembered while the day is switched off. Periods are evaluated as their union, so overlapping or touching periods form
// one continuous operating period.
struct Schedule {
    static constexpr int maxPeriods=3;
    bool enabled=false;
    std::array<bool,7> days{{true,true,true,true,true,false,false}};
    std::array<std::array<Period,maxPeriods>,7> periods{};
    std::array<int,7> counts{{1,1,1,1,1,1,1}};
    void validate(){for(int d=0;d<7;++d){counts[d]=std::clamp(counts[d],1,maxPeriods);for(auto&p:periods[d])if(!p.valid())p=Period{};}}
    bool sameHours(const Schedule&o)const{
        for(int d=0;d<7;++d){if(days[d]!=o.days[d]||counts[d]!=o.counts[d])return false;for(int i=0;i<counts[d];++i)if(!(periods[d][i]==o.periods[d][i]))return false;}
        return true;}
    bool anyDay()const{for(bool d:days)if(d)return true;return false;}
    // `weekMinute` counts from Monday 00:00 (0) to Sunday 23:59 (10079).
    bool allows(int weekMinute)const{
        for(int d=0;d<7;++d)if(days[d])for(int i=0;i<counts[d];++i){const Period&p=periods[d][i];int since=((weekMinute-(d*1440+p.start))%10080+10080)%10080;if(since<p.length())return true;}
        return false;}
    bool allows(const LocalTime&t)const{return allows(t.weekday()*1440+std::clamp(t.minute,0,1439));}
    // Civil seconds from `t` to the next period start or end on a selected day (strictly later), or -1 when no day is selected.
    std::int64_t secondsToBoundary(const LocalTime&t)const{
        const int now=t.weekday()*1440+std::clamp(t.minute,0,1439),second=std::clamp(t.second,0,59);std::int64_t best=-1;
        for(int d=0;d<7;++d)if(days[d])for(int i=0;i<counts[d];++i){const int start=d*1440+periods[d][i].start;
            for(int edge:{start,start+periods[d][i].length()}){int ahead=((edge-now)%10080+10080)%10080;if(ahead==0)ahead=10080;std::int64_t s=std::int64_t(ahead)*60-second;if(best<0||s<best)best=s;}}
        return best;}
    // Quick setup: every day keeps a single 09:00-17:00 period; only the selected days differ. Enabled state is untouched.
    static Schedule preset(bool everyDay){Schedule s;for(int d=0;d<7;++d)s.days[d]=everyDay||d<5;return s;}
};
// The first instant in (from, from+horizon] at which the schedule's verdict differs from its verdict at `from`, or 0 when there
// is none (schedule off, no day selected, or never-changing hours such as every day all day). Boundaries are found in local
// civil time and converted back to UTC seconds. When the UTC offset changes on the way (daylight saving, a time-zone rule) the
// search stops at the first second of the new offset and continues from there, so skipped and repeated local hours are
// evaluated as the clock shows them and no day is assumed to last 24 hours. Touching periods produce no change at all.
inline std::int64_t nextScheduleChange(const Schedule&s,std::int64_t from,const LocalClock&local,std::int64_t horizon=8*86400){
    if(!s.enabled||horizon<=0)return 0;
    LocalTime here=local(from);const bool state=s.allows(here);std::int64_t t=from;
    for(int guard=0;guard<1024;++guard){
        std::int64_t step=s.secondsToBoundary(here);if(step<0)return 0;
        std::int64_t next=t+step;LocalTime there=local(next);const std::int64_t offset=here.civil()-t;
        if(there.civil()-next!=offset){std::int64_t lo=t,hi=next;while(hi-lo>1){std::int64_t mid=lo+(hi-lo)/2;if(local(mid).civil()-mid==offset)lo=mid;else hi=mid;}next=hi;there=local(hi);}
        if(next-from>horizon)return 0;
        if(s.allows(there)!=state)return next;
        t=next;here=there;
    }
    return 0;
}
// The next instant the schedule opens (or closes); 0 when that never happens.
inline std::int64_t nextScheduleTransition(const Schedule&s,std::int64_t from,const LocalClock&local,bool opening){
    if(!s.enabled)return 0;
    std::int64_t change=nextScheduleChange(s,from,local);
    if(s.allows(local(from))!=opening)return change;
    return change?nextScheduleChange(s,change,local):0;}
inline std::int64_t nextScheduleOpening(const Schedule&s,std::int64_t from,const LocalClock&local){return nextScheduleTransition(s,from,local,true);}
inline std::int64_t nextScheduleClosing(const Schedule&s,std::int64_t from,const LocalClock&local){return nextScheduleTransition(s,from,local,false);}
// 24-hour clock text: 540 -> "09:00", 1440 -> "24:00".
inline std::string formatClock(int minutes){minutes=std::clamp(minutes,0,1440);int h=minutes/60,m=minutes%60;std::string s="00:00";s[0]=char('0'+h/10);s[1]=char('0'+h%10);s[3]=char('0'+m/10);s[4]=char('0'+m%10);return s;}
// Reads a typed 24-hour time: "9", "09", "9:30", "09:30", "9.30", "930" or "0930", with surrounding spaces. 24:00 is accepted only
// as an end time. The result is 0..1440 minutes; makePeriod() decides what an end of 00:00 means.
inline bool parseClock(const std::string&text,bool end,int&minutes){
    std::size_t a=text.find_first_not_of(' '),b=text.find_last_not_of(' ');if(a==std::string::npos)return false;
    std::string t=text.substr(a,b-a+1),hours,mins;
    auto digits=[](const std::string&v){return !v.empty()&&std::all_of(v.begin(),v.end(),[](char c){return c>='0'&&c<='9';});};
    auto separator=t.find_first_of(":.");
    if(separator!=std::string::npos){hours=t.substr(0,separator);mins=t.substr(separator+1);if(hours.size()>2||mins.size()!=2)return false;}
    else if(t.size()<=2){hours=t;mins="00";}
    else if(t.size()<=4){hours=t.substr(0,t.size()-2);mins=t.substr(t.size()-2);}
    else return false;
    if(!digits(hours)||!digits(mins))return false;
    int h=std::stoi(hours),m=std::stoi(mins);
    if(m>59||h>24||(h==24&&(m!=0||!end)))return false;
    minutes=h*60+m;return true;
}
struct Settings {
    int workMinutes=20, breakSeconds=20, sound=0, volume=55, mode=0, monitor=0, theme=2;
    bool alarm=true, repeat=false, notifications=true, snooze=true, autoStart=true;
    bool startup=false, tray=true, restore=true, pauseLocked=true, history=true, trayExplained=false, breakModeColors=true;
    bool customWorkAccent=false, customBreakAccent=false;
    theme::Color workAccentColor=theme::rgb(96,165,250), breakAccentColor=theme::rgb(45,212,191);
    std::array<theme::Color,16> pickerCustomColors{{
        theme::rgb(255,255,255),theme::rgb(192,192,192),theme::rgb(128,128,128),theme::rgb(0,0,0),
        theme::rgb(255,0,0),theme::rgb(128,0,0),theme::rgb(255,255,0),theme::rgb(128,128,0),
        theme::rgb(0,255,0),theme::rgb(0,128,0),theme::rgb(0,255,255),theme::rgb(0,128,128),
        theme::rgb(0,0,255),theme::rgb(0,0,128),theme::rgb(255,0,255),theme::rgb(128,0,128)
    }};
    int width=820, height=720, x=-32000, y=-32000;
    std::string selectedMonitor;
    Schedule schedule;
    void validate() {
        workMinutes=std::clamp(workMinutes,1,180); breakSeconds=std::clamp(breakSeconds,5,300);
        sound=std::clamp(sound,0,4); volume=std::clamp(volume,0,100); mode=std::clamp(mode,0,2);
        monitor=std::clamp(monitor,0,2); theme=std::clamp(theme,0,4);
        workAccentColor&=0x00ffffffu; breakAccentColor&=0x00ffffffu;
        for(auto& color:pickerCustomColors)color&=0x00ffffffu;
        width=std::clamp(width,520,2560); height=std::clamp(height,480,2160);
        if(selectedMonitor.size()>128) selectedMonitor.clear();
        schedule.validate();
    }
};
struct Record { std::int64_t at=0; bool completed=false; double seconds=0; };
struct Saved { int phase=0; bool paused=false; double remaining=1200, duration=1200; std::uint64_t cycle=1; std::int64_t at=0; };
// `paused` is the user's Pause (or lock pause); `held` means the operating schedule is closed. They are independent.
struct Snapshot { Phase phase; bool paused; double remaining, duration; std::uint64_t cycle; bool held;
    double progress() const {return std::clamp(1-remaining/duration,0.0,1.0);} };
class Engine {
    Settings settings;
    std::function<double()> monotonic;
    std::function<std::int64_t()> utc;
    LocalClock local;
    Phase phase=Phase::Work;
    // `held`: outside operating hours, so automatic operation is stopped. `manual`: the current break was requested by the user.
    bool paused=false, suspended=false, lockPause=false, held=false, manual=false;
    double remaining=1200, duration=1200, anchor=0;
    std::int64_t suspendedAt=0, suspendedSince=0;
    std::uint64_t cycle=1;
    // A held work countdown stands still; a break the user started keeps running outside operating hours.
    bool running() const {return !paused&&!suspended&&!(held&&phase!=Phase::Break);}
    double nowRemaining() const {return running()?std::max(0.0,remaining-(monotonic()-anchor)):remaining;}
    // Whether time away (sleep, or a lock without lock pause) counts as elapsed countdown time.
    bool countsAway() const {return !paused&&!lockPause&&!(held&&phase!=Phase::Break);}
    void begin(Phase next,double seconds,bool stop=false) {
        phase=next; remaining=duration=seconds; paused=stop; manual=false; anchor=monotonic(); ++cycle;
        if(changed)changed();
    }
    void record(bool completed) {if(ended)ended({utc(),completed,std::clamp(duration-nowRemaining(),0.0,duration)});}
    // Outside operating hours only a break the user asks for can start, and it starts without the alarm.
    void startBreak(bool byUser) {begin(Phase::Break,settings.breakSeconds);manual=byUser;if(due)due(cycle,settings.alarm&&!held);}
    // Only a countdown that reaches zero while running announces completion. The callback follows begin(), so the
    // finished break's UI teardown has already happened and the completion alarm is not stopped by it. It is silent
    // outside operating hours.
    void completeBreak() {auto finished=cycle;bool sound=settings.alarm&&!held;finish(true);if(breakCompleted)breakCompleted(finished,sound);}
    bool allowsAt(std::int64_t t) const {return !settings.schedule.enabled||settings.schedule.allows(local(t));}
    bool scheduleChangedBetween(std::int64_t a,std::int64_t b) const {
        if(!settings.schedule.enabled||a==b)return false;
        // The schedule repeats weekly, so a change that exists at all occurs within any 8-day span.
        std::int64_t lo=std::min(a,b),hi=std::max(a,b);return nextScheduleChange(settings.schedule,lo,local,std::min<std::int64_t>(hi-lo,8*86400))!=0;
    }
    // The operating period closed. A pending automatic break or snooze is cancelled without a history record (the user neither
    // completed nor skipped it) and a running work countdown becomes a fresh interval that stands still until the next opening.
    // A manual pause keeps its remaining time, and a break the user started runs to its end.
    void hold() {
        remaining=nowRemaining();anchor=monotonic();held=true;
        if(phase==Phase::Snooze||(phase==Phase::Break&&!manual)||(phase==Phase::Work&&!paused))begin(Phase::Work,settings.workMinutes*60,paused);
        else if(changed)changed();
    }
    // An operating period began. Time outside it never counts as work, so a running countdown starts a fresh full interval.
    void release() {
        remaining=nowRemaining();anchor=monotonic();held=false;
        if(phase==Phase::Work&&!paused)begin(Phase::Work,settings.workMinutes*60);
        else if(changed)changed();
    }
    void syncSchedule() {if(suspended)return;bool open=allowsAt(utc());if(held&&open)release();else if(!held&&!open)hold();}
public:
    std::function<void()> changed;
    std::function<void(std::uint64_t,bool)> due;
    std::function<void(std::uint64_t,bool)> breakCompleted;
    std::function<void(Record)> ended;
    Engine(Settings s,std::function<double()> mono,std::function<std::int64_t()> wall,LocalClock calendar=utcCalendar):settings(s),monotonic(std::move(mono)),utc(std::move(wall)),local(std::move(calendar)) {
        settings.validate(); remaining=duration=settings.workMinutes*60; paused=!settings.autoStart;anchor=monotonic();held=!allowsAt(utc());
    }
    void configure(Settings s) {s.validate();settings=s;syncSchedule();}
    Snapshot snapshot()const{return{phase,paused||lockPause,nowRemaining(),duration,cycle,held};}
    bool isSuspended()const{return suspended;}
    bool scheduled()const{return settings.schedule.enabled;}
    bool scheduleOpen()const{return allowsAt(utc());}
    // The next instant (UTC seconds) at which the schedule opens or closes, or 0 when it is off or never changes.
    std::int64_t scheduleBoundary()const{return nextScheduleChange(settings.schedule,utc(),local);}
    // The schedule is evaluated before a due countdown can start a break, so a deadline that coincides with a closing never
    // produces a reminder.
    void tick() {syncSchedule();if(!running()||nowRemaining()>0)return;if(phase==Phase::Break)completeBreak();else startBreak(false);}
    void pause() {if(paused)return;remaining=nowRemaining();anchor=monotonic();paused=true;if(changed)changed();}
    // Resume never overrides the schedule: outside operating hours the countdown stays held and starts at the next opening.
    void resume() {if(!paused)return;if(held&&phase==Phase::Work){begin(Phase::Work,settings.workMinutes*60);return;}anchor=monotonic();paused=false;if(changed)changed();tick();}
    void reset() {if(phase==Phase::Break)record(false);begin(Phase::Work,settings.workMinutes*60,paused);}
    void takeBreak() {if(phase!=Phase::Break&&!suspended)startBreak(true);}
    void finish(bool completed) {if(phase!=Phase::Break)return;record(completed);begin(Phase::Work,settings.workMinutes*60);}
    // Snoozing schedules an automatic reminder, so it is unavailable outside operating hours.
    void snooze(int minutes) {if(phase==Phase::Break&&!held&&settings.snooze&&(minutes==1||minutes==3||minutes==5))begin(Phase::Snooze,minutes*60);}
    void suspend(bool locked) {
        if(suspended){
            if(locked&&settings.pauseLocked&&!lockPause){if(countsAway())remaining=std::max(0.0,remaining-double(std::max<std::int64_t>(0,utc()-suspendedAt)));lockPause=true;suspendedAt=utc();if(changed)changed();}
            return;
        }
        remaining=nowRemaining();anchor=monotonic();lockPause=locked&&settings.pauseLocked;suspendedAt=suspendedSince=utc();suspended=true;if(changed)changed();
    }
    void wake() {
        if(!suspended)return;
        const std::int64_t now=utc();double absent=double(std::max<std::int64_t>(0,now-suspendedAt));bool counts=countsAway();suspended=false;anchor=monotonic();
        if(scheduleChangedBetween(suspendedSince,now)){
            // An operating boundary passed while away. Nothing outside operating hours is owed: an automatic break or snooze ends
            // without a history record, running work restarts fresh if a period is open now, and a manual pause is kept.
            if(phase==Phase::Break&&manual&&counts){remaining=std::max(0.0,remaining-absent);if(remaining<=0){record(false);begin(Phase::Work,settings.workMinutes*60);}}
            lockPause=false;
            if(phase==Phase::Break&&manual){if(changed)changed();}else hold();
            tick();return;
        }
        if(counts){remaining=std::max(0.0,remaining-absent);if(remaining<=0&&phase==Phase::Break){record(false);begin(Phase::Work,settings.workMinutes*60);}}
        lockPause=false;if(changed)changed();tick();
    }
    Saved save()const{return{int(phase),paused,nowRemaining(),duration,cycle,utc()};}
    bool restore(const Saved& s) {
        if(!settings.restore||s.phase<0||s.phase>2||!std::isfinite(s.remaining)||!std::isfinite(s.duration)||s.duration<=0||s.duration>10800||s.remaining<0||s.remaining>s.duration||!s.cycle||s.at<1577836800)return false;
        const std::int64_t now=utc();double elapsed=double(std::max<std::int64_t>(0,now-s.at));
        if(settings.schedule.enabled&&(!allowsAt(now)||scheduleChangedBetween(s.at,now))){
            // Reopened outside operating hours, or after an inactive gap: downtime is not work and no reminder is replayed.
            held=!allowsAt(now);
            if(s.paused&&s.phase==int(Phase::Work)){phase=Phase::Work;paused=true;manual=false;remaining=s.remaining;duration=s.duration;cycle=s.cycle;anchor=monotonic();if(changed)changed();return true;}
            begin(Phase::Work,settings.workMinutes*60,s.paused||!settings.autoStart);return true;
        }
        held=false;
        if(s.phase==int(Phase::Break)||(!s.paused&&elapsed>=s.remaining)){begin(Phase::Work,settings.workMinutes*60,s.paused||!settings.autoStart);return true;}
        phase=Phase(s.phase);paused=s.paused;remaining=std::max(0.0,s.remaining-(paused?0:elapsed));duration=s.duration;cycle=s.cycle;anchor=monotonic();if(changed)changed();return true;
    }
};
// Schedule lines in settings.ini, after the other preferences, all with integer values so that earlier versions (which skip
// unknown integer keys) still read the file:
//   schedule=0|1                    operating schedule on or off
//   scheduleMonday=0|1              day selected (Monday ... Sunday)
//   scheduleMonday1=HHMMHHMM        period 1..3 start and end, e.g. 09001700; an end of 2400 is midnight
// A day without period lines keeps the default 09:00-17:00. Unknown period numbers are ignored; malformed values reject the file.
inline std::string clockDigits(int minutes){auto text=formatClock(minutes);return text.substr(0,2)+text.substr(3,2);}
inline bool decodePeriod(int value,Period&out){
    if(value<0||value>99999999)return false;
    auto minutes=[](int hhmm,bool end,int&result){int h=hhmm/100,m=hhmm%100;if(m>59||h>24||(h==24&&(m!=0||!end)))return false;result=h*60+m;return true;};
    int start=0,end=0;return minutes(value/10000,false,start)&&minutes(value%10000,true,end)&&makePeriod(start,end,out);
}
inline std::string encodeSettings(const Settings&s) {
    std::ostringstream o;
#define EYE_WRITE(field) o<<#field<<'='<<s.field<<'\n'
    EYE_WRITE(workMinutes);EYE_WRITE(breakSeconds);EYE_WRITE(sound);EYE_WRITE(volume);EYE_WRITE(mode);EYE_WRITE(monitor);EYE_WRITE(theme);EYE_WRITE(breakModeColors);
    EYE_WRITE(customWorkAccent);EYE_WRITE(customBreakAccent);EYE_WRITE(workAccentColor);EYE_WRITE(breakAccentColor);
    for(std::size_t i=0;i<s.pickerCustomColors.size();++i)o<<"pickerCustomColor"<<i<<'='<<(s.pickerCustomColors[i]&0x00ffffffu)<<'\n';
    EYE_WRITE(alarm);EYE_WRITE(repeat);EYE_WRITE(notifications);EYE_WRITE(snooze);EYE_WRITE(autoStart);EYE_WRITE(startup);EYE_WRITE(tray);
    EYE_WRITE(restore);EYE_WRITE(pauseLocked);EYE_WRITE(history);EYE_WRITE(trayExplained);EYE_WRITE(width);EYE_WRITE(height);EYE_WRITE(x);EYE_WRITE(y);EYE_WRITE(selectedMonitor);
#undef EYE_WRITE
    o<<"schedule="<<s.schedule.enabled<<'\n';
    for(int d=0;d<7;++d){o<<"schedule"<<scheduleDayNames[d]<<'='<<s.schedule.days[d]<<'\n';
        for(int i=0;i<s.schedule.counts[d];++i){auto&p=s.schedule.periods[d][i];o<<"schedule"<<scheduleDayNames[d]<<i+1<<'='<<clockDigits(p.start)<<clockDigits(p.end)<<'\n';}}
    return o.str();
}
inline bool decodeSettings(const std::string& text, Settings& out) {
    if(text.size()>65536)return false;
    Settings s;std::istringstream input(text);std::string line;int count=0;bool hasWorkAccentColor=false,hasBreakAccentColor=false;
    std::array<std::array<int,Schedule::maxPeriods>,7> stored;for(auto&day:stored)day.fill(-1);
    while(std::getline(input,line)) {
        if(line.empty())continue;
        auto eq=line.find('=');if(eq==std::string::npos)return false;
        auto key=line.substr(0,eq),value=line.substr(eq+1);if(!value.empty()&&value.back()=='\r')value.pop_back();++count;
        if(key=="selectedMonitor"){if(value.size()>128||value.find('\r')!=std::string::npos)return false;s.selectedMonitor=value;continue;}
        if(key=="workAccentColor"||key=="breakAccentColor"||key=="customWorkAccent"||key=="customBreakAccent"){
            int n=0;bool valid=false;try{std::size_t used=0;n=std::stoi(value,&used);valid=used==value.size();}catch(...){}
            if(key=="customWorkAccent"){s.customWorkAccent=valid&&(n==1);continue;}
            if(key=="customBreakAccent"){s.customBreakAccent=valid&&(n==1);continue;}
            const bool inRange=valid&&n>=0&&n<=0x00ffffff;
            if(key=="workAccentColor"){hasWorkAccentColor=inRange;if(inRange)s.workAccentColor=theme::Color(n);else s.customWorkAccent=false;}
            else{hasBreakAccentColor=inRange;if(inRange)s.breakAccentColor=theme::Color(n);else s.customBreakAccent=false;}
            continue;
        }
        int pickerIndex=-1;for(int i=0;i<16;++i)if(key=="pickerCustomColor"+std::to_string(i)){pickerIndex=i;break;}
        if(pickerIndex>=0){int n=0;bool valid=false;try{std::size_t used=0;n=std::stoi(value,&used);valid=used==value.size();}catch(...){}if(valid&&n>=0&&n<=0x00ffffff)s.pickerCustomColors[pickerIndex]=theme::Color(n);else s.pickerCustomColors[pickerIndex]=Settings{}.pickerCustomColors[pickerIndex];continue;}
        int n=0;try{std::size_t used=0;n=std::stoi(value,&used);if(used!=value.size())return false;}catch(...){return false;}
#define EYE_INT(field) if(key==#field){s.field=n;continue;}
#define EYE_BOOL(field) if(key==#field){if(n!=0&&n!=1)return false;s.field=n!=0;continue;}
        EYE_INT(workMinutes);EYE_INT(breakSeconds);EYE_INT(sound);EYE_INT(volume);EYE_INT(mode);EYE_INT(monitor);EYE_INT(theme);EYE_INT(width);EYE_INT(height);EYE_INT(x);EYE_INT(y);
        EYE_BOOL(alarm);EYE_BOOL(repeat);EYE_BOOL(notifications);EYE_BOOL(snooze);EYE_BOOL(autoStart);EYE_BOOL(startup);EYE_BOOL(tray);EYE_BOOL(restore);EYE_BOOL(pauseLocked);EYE_BOOL(history);EYE_BOOL(trayExplained);EYE_BOOL(breakModeColors);
#undef EYE_INT
#undef EYE_BOOL
        if(key=="schedule"){if(n!=0&&n!=1)return false;s.schedule.enabled=n!=0;continue;}
        for(int d=0;d<7;++d){std::string day=std::string("schedule")+scheduleDayNames[d];if(key.compare(0,day.size(),day)!=0)continue;
            std::string rest=key.substr(day.size());
            if(rest.empty()){if(n!=0&&n!=1)return false;s.schedule.days[d]=n!=0;}
            else if(rest.size()==1&&rest[0]>='1'&&rest[0]<='0'+Schedule::maxPeriods){Period p;if(!decodePeriod(n,p))return false;stored[d][rest[0]-'1']=n;}
            break;}
    }
    if(count==0)return false;
    if(!hasWorkAccentColor)s.customWorkAccent=false;
    if(!hasBreakAccentColor)s.customBreakAccent=false;
    for(int d=0;d<7;++d){int k=0;for(int value:stored[d])if(value>=0)decodePeriod(value,s.schedule.periods[d][k++]);if(k)s.schedule.counts[d]=k;}
    s.validate();out=s;return true;
}
inline std::string encodeTimer(const Saved&s) {std::ostringstream o;o<<std::setprecision(17)<<s.phase<<' '<<s.paused<<' '<<s.remaining<<' '<<s.duration<<' '<<s.cycle<<' '<<s.at;return o.str();}
inline bool decodeTimer(const std::string&text,Saved&out) {if(text.size()>1024)return false;std::istringstream i(text);Saved s;int pause;
    if(!(i>>s.phase>>pause>>s.remaining>>s.duration>>s.cycle>>s.at)||pause<0||pause>1)return false;
    i>>std::ws;if(!i.eof())return false;s.paused=pause!=0;out=s;return true;}
inline std::string encodeHistory(const std::vector<Record>& records) {std::ostringstream o;o<<std::setprecision(17);for(auto&r:records)o<<r.at<<' '<<r.completed<<' '<<r.seconds<<'\n';return o.str();}
inline bool decodeHistory(const std::string&text,std::vector<Record>&out,std::int64_t now) {
    if(text.size()>2*1024*1024)return false;
    std::istringstream i(text);std::string line;std::vector<Record> list;
    while(std::getline(i,line)){if(line.empty())continue;std::istringstream row(line);Record r;int complete;
        if(!(row>>r.at>>complete>>r.seconds)||complete<0||complete>1||!std::isfinite(r.seconds)||r.seconds<0||r.seconds>10800||r.at<1577836800||r.at>now+86400)return false;
        row>>std::ws;if(!row.eof())return false;r.completed=complete!=0;list.push_back(r);}
    if(list.size()>10000)list.erase(list.begin(),list.end()-10000);
    out=std::move(list);return true;
}
struct Stats {int todayCompleted=0,todaySkipped=0,weekCompleted=0,totalCompleted=0,streak=0;double completion=0;};
// Calendar day and week boundaries are supplied by the OS adapter, never inferred from UTC days.
inline Stats statistics(const std::vector<Record>&records,int today,int monday,const std::function<int(std::int64_t)>&day) {
    Stats s;std::map<int,bool> completedDays;
    for(auto&r:records){int d=day(r.at);if(r.completed){++s.totalCompleted;completedDays[d]=true;if(d>=monday&&d<=today)++s.weekCompleted;}
        if(d==today){if(r.completed)++s.todayCompleted;else ++s.todaySkipped;}}
    int count=s.todayCompleted+s.todaySkipped;s.completion=count?100.0*s.todayCompleted/count:0;
    int cursor=completedDays.count(today)?today:today-1;while(completedDays.count(cursor--))++s.streak;return s;
}
// Pure layout arithmetic shared by the Windows UI and the tests. All inputs are device pixels except where noted "logical".
namespace geometry {
// Logical (96 DPI) length to device pixels at the given DPI.
inline int scaled(double logical,int dpi){return int(std::lround(logical*dpi/96.0));}
inline constexpr double timerProgressStartDegrees=-90.0; // GDI+ uses a downward y-axis, so -90 degrees is 12 o'clock.
// Clockwise sweep for a clamped Timer ring. Kept pure so the 0/25/50/75/100% geometry can be checked without GDI+.
inline double timerProgressSweep(double progress){return 360.0*std::clamp(progress,0.0,1.0);}
inline constexpr int timerHeaderTitleWidth=120,timerHeaderTopInset=1,timerHeaderRowGap=4;
inline int timerHeaderHeight(int dpi,double textScale){return scaled(std::max(38.0,20.0*textScale),dpi);}
inline int timerHeaderCaptionOffset(int dpi,double textScale){return scaled(timerHeaderTopInset,dpi)+timerHeaderHeight(dpi,textScale)+scaled(timerHeaderRowGap,dpi);}
inline int timerRingTopOffset(int dpi){return scaled(88,dpi)+scaled(8,dpi);}
struct TimerStatusBounds {int left=0,width=0;};
inline TimerStatusBounds timerStatusBounds(int ringLeft,int ringDiameter){return {ringLeft,std::max(1,ringDiameter)};}
// Maximum width of a rectangular label that stays inside a stroked circular ring. `top` is relative to the ring ellipse.
inline int circleLabelWidth(int diameter,int strokeWidth,int top,int height){
    if(diameter<=0||strokeWidth<0||height<=0)return 0;
    const double radius=std::max(0.0,diameter/2.0-strokeWidth/2.0-1.0),center=diameter/2.0;
    const double farthest=std::max(std::abs(double(top)-center),std::abs(double(top+height)-center));
    if(farthest>=radius)return 0;
    return std::max(0,int(std::floor(2.0*std::sqrt(radius*radius-farthest*farthest)))-1);
}
// The Settings shell: ONE rectangle, centred in the window, at most 640 logical px wide with a 24 logical px outer margin. The tab
// bar, the section row, the page heading, the scroll viewport (including its scroll bar) and the History list all use exactly this
// rectangle, so they share one left edge and one right edge.
struct Column {int x=0,width=0;};
inline Column contentColumn(int clientWidth,int dpi){
    int available=std::max(scaled(320,dpi),clientWidth-2*scaled(24,dpi));
    Column c;c.width=std::max(scaled(200,dpi),std::min(available,scaled(640,dpi)));c.x=(clientWidth-c.width)/2;return c;
}
// Segmented navigation: equal widths when every caption fits on one row, otherwise widths follow the captions and the
// segments wrap onto further rows. Rows with several segments are stretched to exactly fill the width; a row holding a single
// segment keeps the cell width of the row above so it reads as part of the grid rather than a full-width bar.
struct Segment {int index=0,row=0,x=0,width=0;};
inline std::vector<Segment> segmentRows(const std::vector<int>&natural,int x0,int width,int gap,int minimum,bool allowWrap=true){
    std::vector<Segment> out;int n=int(natural.size());if(n==0)return out;
    int widest=*std::max_element(natural.begin(),natural.end()),usable=width-(n-1)*gap;
    if(usable/n>=widest){
        for(int i=0;i<n;++i){int left=x0+usable*i/n+i*gap,right=i==n-1?x0+width:x0+usable*(i+1)/n+i*gap;out.push_back({i,0,left,std::max(minimum,right-left)});}
        return out;
    }
    if(!allowWrap){ // one row whose widths follow the captions in proportion; used by the primary tab bar
        long long sum=0;for(int v:natural)sum+=v;int x=x0;
        for(int i=0;i<n;++i){int w=i==n-1?x0+width-x:std::max(minimum,int((long long)natural[i]*usable/std::max<long long>(1,sum)));if(i==n-1)w=std::max(minimum,w);out.push_back({i,0,x,w});x+=w+gap;}
        return out;
    }
    std::vector<std::vector<int>> rows(1);int rowWidth=0;
    for(int i=0;i<n;++i){int need=natural[i]+(rows.back().empty()?0:gap);if(!rows.back().empty()&&rowWidth+need>width){rows.emplace_back();rowWidth=0;need=natural[i];}rows.back().push_back(i);rowWidth+=need;}
    int previousCell=width;
    for(int r=0;r<int(rows.size());++r){auto&row=rows[r];int count=int(row.size()),used=0;for(int i:row)used+=natural[i];int extra=std::max(0,width-used-(count-1)*gap),x=x0;
        if(count==1&&r>0){int i=row[0];int w=std::min(width,std::max(natural[i],previousCell));out.push_back({i,r,x0,std::max(minimum,w)});continue;}
        for(int k=0;k<count;++k){int i=row[k];int w=natural[i]+extra/count;if(k==count-1)w=x0+width-x;if(k==0)previousCell=std::max(minimum,w);out.push_back({i,r,x,std::max(minimum,w)});x+=w+gap;}}
    return out;
}
// Settings form placement. Items are laid out in content coordinates (x is measured from the pane edge, `inset` is the left
// margin). Headings, hints and check boxes span the content width. A caption and the field after it sit side by side when
// the column is wide enough for every caption, otherwise the caption stacks above its field. A slider may be followed by a
// value label on the same row; buttons flow left to right and wrap when they no longer fit. An Inline row (labels, short
// fields and buttons of a requested `width`, all field height) flows the same way; an item marked `keep` (a label) wraps
// together with the item after it.
enum class FormKind {Plain,Heading,Caption,Hint,Check,Field,Slider,Value,Button,Inline};
struct FormItem {FormKind kind=FormKind::Plain;int textWidth=0;std::function<int(int)> textHeight;bool sameRow=false,indent=false,spin=false,keep=false;int width=0;};
struct FormBox {int x=0,y=0,w=0,h=0,spinWidth=0;};
struct Form {std::vector<FormBox> boxes;int height=0;bool sideBySide=false;};
// Captions sit beside their fields only when the column is wide enough and every caption fits the label column.
inline bool sideBySide(int contentWidth,int widestCaption,int labelWidth,int minimumContentWidth){return contentWidth>=minimumContentWidth&&widestCaption<=labelWidth;}
inline Form layoutForm(const std::vector<FormItem>&items,int contentW,int inset,int dpi,double textScale){
    auto px=[&](double v){return scaled(v,dpi);};
    Form out;out.boxes.assign(items.size(),FormBox{});
    const int fieldH=px(std::max(32.0,21.0*textScale)),labelW=px(210),colGap=px(16),valueW=px(52);
    int widest=0;for(auto&item:items)if(item.kind==FormKind::Caption)widest=std::max(widest,item.textWidth);
    out.sideBySide=sideBySide(contentW,widest,labelW,px(500));
    auto heightAt=[&](const FormItem&item,int width){return item.textHeight?item.textHeight(std::max(1,width)):px(20);};
    auto box=[&](std::size_t n,int x,int y,int w,int h){out.boxes[n]=FormBox{x,y,w,h,0};};
    auto gapFor=[&](FormKind before,FormKind next)->int{
        if(next==FormKind::Heading){return px(26);}
        if(before==FormKind::Heading){return px(10);}
        if(next==FormKind::Hint){return px(4);}
        if(before==FormKind::Hint){return px(12);}
        if(before==FormKind::Check&&next==FormKind::Check){return px(2);}
        if(before==FormKind::Check&&next==FormKind::Inline){return px(4);}
        if(before==FormKind::Inline&&next==FormKind::Inline){return px(6);}
        if(next==FormKind::Button){return px(18);}
        return px(14);
    };
    int y=px(4);FormKind previous=FormKind::Plain;bool first=true;
    for(std::size_t i=0;i<items.size();++i){
        const FormItem&c=items[i];if(c.sameRow)continue;
        if(!first)y+=gapFor(previous,c.kind);
        first=false;FormKind placed=c.kind;
        switch(c.kind){
            case FormKind::Heading:{int h=heightAt(c,contentW)+px(4);box(i,inset,y,contentW,h);y+=h;break;}
            case FormKind::Check:{int h=std::max(px(std::max(30.0,20.0*textScale)),heightAt(c,contentW-px(34))+px(10));box(i,inset,y,contentW,h);y+=h;break;}
            case FormKind::Caption:{
                const FormItem*field=i+1<items.size()?&items[i+1]:nullptr;
                if(!field){int h=heightAt(c,contentW)+px(2);box(i,inset,y,contentW,h);y+=h;break;}
                // Fields run to the column edge so every right edge lines up with the divider and the section row.
                int spin=field->spin?px(24):0;
                int controlW=field->spin?px(132):(out.sideBySide?contentW-labelW-colGap:contentW);int fx=inset,fy=y;
                if(out.sideBySide){box(i,inset,y,labelW,fieldH);fx=inset+labelW+colGap;y+=fieldH;}
                else{int captionH=heightAt(c,contentW)+px(2);box(i,inset,y,contentW,captionH);y+=captionH+px(6);fy=y;y+=fieldH;}
                if(field->kind==FormKind::Slider){
                    bool hasValue=i+2<items.size()&&items[i+2].sameRow;int sliderW=controlW-(hasValue?valueW+px(8):0);
                    box(i+1,fx,fy,sliderW,fieldH);if(hasValue){box(i+2,fx+sliderW+px(8),fy,valueW,fieldH);++i;}
                }else{box(i+1,fx,fy,controlW-spin,fieldH);out.boxes[i+1].spinWidth=spin;}
                ++i;placed=FormKind::Field;break;}
            case FormKind::Button:{
                int x=inset,h=fieldH;auto natural=[&](const FormItem&b){return std::min(contentW,std::max(px(112),b.textWidth+px(40)));};
                int bw=natural(c);box(i,x,y,bw,h);x+=bw;
                while(i+1<items.size()&&items[i+1].sameRow){++i;int w2=natural(items[i]);if(x+px(10)+w2>inset+contentW){y+=h+px(8);x=inset;}else{x+=px(10);}box(i,x,y,w2,h);x+=w2;}
                y+=h;break;}
            case FormKind::Inline:{
                const int left=inset+(c.indent?px(32):0),right=inset+contentW,gap=px(8);int x=left,rowY=y;
                auto widthOf=[&](std::size_t n){return std::max(1,std::min(items[n].width,right-left));};
                for(std::size_t n=i;;++n){
                    int need=widthOf(n);if(items[n].keep&&n+1<items.size()&&items[n+1].sameRow)need+=gap+widthOf(n+1);
                    if(x>left&&x+need>right){rowY+=fieldH+px(6);x=left;}
                    box(n,x,rowY,widthOf(n),fieldH);x+=widthOf(n)+gap;i=n;
                    if(n+1>=items.size()||!items[n+1].sameRow)break;}
                y=rowY+fieldH;break;}
            default:{int indent=c.indent?px(32):0;int h=heightAt(c,contentW-indent)+px(2);box(i,inset+indent,y,contentW-indent,h);y+=h;break;}
        }
        previous=placed;
    }
    out.height=y;return out;
}
}
// Scroll position with a wheel accumulator and a short ease-out animation. Units are the caller's (pixels or list rows).
// Input moves the target immediately and is never queued: the position closes on the target and stops when it arrives.
class ScrollModel {
    double current=0, goal=0, limit=0, snap=1;
    double bounded(double value) const {return std::clamp(value,0.0,limit);}
public:
    static constexpr double settleSeconds=0.045; // time constant: about 0.2 s to settle after one wheel notch
    explicit ScrollModel(double snapDistance=1) : snap(snapDistance) {}
    void setRange(double maximum) {limit=std::max(0.0,maximum);current=bounded(current);goal=bounded(goal);}
    void rescale(double factor) {if(factor>0&&std::isfinite(factor)){current*=factor;goal*=factor;}}
    // delta is in wheel units (120 per notch, smaller for high-resolution wheels and trackpads); the fractional
    // remainder stays in the target, so small deltas accumulate instead of being dropped.
    void wheel(int delta,double amountPerNotch,bool animate) {scrollTo(goal-double(delta)*amountPerNotch/120.0,animate);}
    void scrollBy(double amount,bool animate) {scrollTo(goal+amount,animate);}
    void scrollTo(double value,bool animate) {goal=bounded(value);if(!animate)current=goal;}
    void jump(double value) {current=goal=bounded(value);}
    void finish() {current=goal;}
    // Advances the animation; returns true while more steps are needed.
    bool step(double seconds) {
        if(current==goal)return false;
        current+=(goal-current)*(1-std::exp(-std::max(0.0,seconds)/settleSeconds));
        if(std::fabs(goal-current)<snap)current=goal;
        return current!=goal;
    }
    bool animating() const {return current!=goal;}
    double position() const {return current;}
    double target() const {return goal;}
    double maximum() const {return limit;}
    int pixel() const {return int(std::lround(current));}
};
}
