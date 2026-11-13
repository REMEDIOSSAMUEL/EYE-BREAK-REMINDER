#include "../src/core.hpp"
#include "../src/theme.hpp"
#include "../src/update_checker.hpp"
#include <iostream>
#include <cstdlib>
#include <iomanip>
using namespace eye;
static int checks=0;
void expect(bool condition,const char* name){if(!condition){std::cerr<<"FAIL: "<<name<<'\n';std::exit(1);}++checks;}
// Optional accounting: `core-tests -v` prints how many assertions and parameter combinations each block contributed.
struct Account {std::string name;int checksAtStart=0,combinations=0;};
static std::vector<Account> accounts;
void block(const std::string&name){accounts.push_back({name,checks,0});}
void combination(){if(!accounts.empty())++accounts.back().combinations;}
// The local calendar is synthetic: UTC shifted by `zone` seconds, plus one hour while dstFrom <= t < dstTo. Nothing depends on the
// test machine's clock, time zone or weekday.
struct Fixture {double mono=0;std::int64_t wall=1791288000,zone=0,dstFrom=0,dstTo=0;Settings s;Engine e;int reminders=0,alarms=0,completions=0,completionAlarms=0;std::uint64_t completedCycle=0;std::vector<Record>records;std::vector<std::int64_t>dueAt;
 Fixture(Settings value={},std::int64_t start=1791288000):wall(start),s(value),e(s,[this]{return mono;},[this]{return wall;},[this](std::int64_t t){return utcCalendar(t+offset(t));}){e.due=[this](auto,bool sound){++reminders;if(sound)++alarms;dueAt.push_back(wall);};e.ended=[this](Record r){records.push_back(r);};e.breakCompleted=[this](std::uint64_t cycle,bool sound){++completions;completedCycle=cycle;if(sound)++completionAlarms;};}
 std::int64_t offset(std::int64_t t)const{return zone+(t>=dstFrom&&t<dstTo?3600:0);}
 void advance(double seconds){mono+=seconds;wall+=static_cast<std::int64_t>(seconds);} };
void geometryTests();
void scheduleTests();
int main(int argc,char**argv){
 block("theme palette contrast and Windows preference resolution");
 for(auto mode:{theme::Mode::Light,theme::Mode::Dark,theme::Mode::HighContrastDark,theme::Mode::HighContrastLight}){
  const auto palette=theme::resolve(mode,false);combination();expect(theme::contrastRatio(palette.foreground,palette.background)>=4.5,"normal text reaches AA contrast against the theme background");
  combination();expect(theme::contrastRatio(palette.secondary,palette.background)>=4.5,"secondary text remains readable");
  combination();expect(theme::contrastRatio(palette.workAccent,palette.background)>=3.0&&theme::contrastRatio(palette.breakAccent,palette.background)>=3.0,"work and break indicators remain distinct from the background");
  combination();expect(theme::contrastRatio(palette.workButtonText,palette.workAccent)>=4.5&&theme::contrastRatio(palette.breakButtonText,palette.breakAccent)>=4.5,"primary button labels remain readable");
  if(palette.highContrast){combination();expect(theme::contrastRatio(palette.foreground,palette.background)>=7.0,"high contrast theme exceeds AAA text contrast");}
 }
 combination();expect(theme::resolve(theme::Mode::FollowWindows,true).dark,"Follow Windows resolves to dark");
 combination();expect(!theme::resolve(theme::Mode::FollowWindows,false).dark,"Follow Windows resolves to light");
 combination();expect(Settings{}.theme==int(theme::Mode::Dark),"fresh settings default to the existing dark appearance");
 block("custom accent colour parsing and text contrast");
 {theme::Color parsed=0;combination();expect(theme::parseHexColor("#3B82F6",parsed)&&parsed==theme::rgb(59,130,246),"hex RGB channels parse in red-green-blue order");
  combination();expect(theme::parseHexColor("ff8800",parsed)&&parsed==theme::rgb(255,136,0),"hex parser accepts six digit values with lowercase letters");
  combination();expect(theme::formatHexColor(parsed)=="#FF8800","hex values display in canonical uppercase form");
  theme::Color unchanged=parsed;combination();expect(!theme::parseHexColor("#12G456",parsed)&&parsed==unchanged,"invalid hex leaves the prior colour untouched");
  combination();expect(!theme::parseHexColor("12345",parsed),"short RGB values are rejected");
  for(theme::Color color:{theme::rgb(0,0,0),theme::rgb(255,255,255),theme::rgb(255,0,255),theme::rgb(255,255,0)}){
   const theme::Color buttonText=theme::readableButtonText(color);combination();expect(theme::contrastRatio(buttonText,color)>=4.5,"extreme accent colours receive readable primary-button text");
   for(theme::Color background:{theme::rgb(26,29,35),theme::rgb(247,248,250)}){const auto text=theme::readableAccentText(color,background);combination();expect(theme::contrastRatio(text,background)>=4.5,"extreme accent status text is adjusted for theme contrast");}
  }
 }
 block("semantic versions and deterministic release-check responses");
 {updates::Version stable,preview;combination();expect(updates::detail::parseVersion("v1.2.3",stable),"parse a GitHub v-prefixed release tag");
  combination();expect(updates::detail::parseVersion("1.2.3-rc.2",preview)&&updates::detail::compare(preview,stable)<0,"stable version sorts after its prerelease");
  updates::Version rc10,rc2;updates::detail::parseVersion("1.2.3-rc.10",rc10);updates::detail::parseVersion("1.2.3-rc.2",rc2);combination();expect(updates::detail::compare(rc10,rc2)>0,"numeric prerelease identifiers compare numerically");
  updates::Version buildA,buildB;updates::detail::parseVersion("1.2.3+build.1",buildA);updates::detail::parseVersion("1.2.3+build.2",buildB);combination();expect(updates::detail::compare(buildA,buildB)==0,"build metadata does not change semantic precedence");
  combination();expect(!updates::detail::parseVersion("1.02.3",preview),"reject non-semantic leading zeroes");
  const std::string body=R"({"tag_name":"v1.2.0","html_url":"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.2.0","draft":false,"prerelease":false,"assets":[]})";
  auto result=updates::evaluate({200,body,updates::Failure::None,0},"1.1.0");combination();expect(result.state==updates::State::UpdateAvailable&&result.latestVersion=="1.2.0"&&!result.releaseUrl.empty(),"newer official stable release is available");
  result=updates::evaluate({200,body,updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::UpToDate,"same installed version reports current");
  result=updates::evaluate({200,body,updates::Failure::None,0},"1.3.0");combination();expect(result.state==updates::State::InstalledNewer,"older latest release does not claim an update is available");
  const std::string prerelease=R"({"tag_name":"v1.3.0-rc.1","html_url":"https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.3.0-rc.1","draft":false,"prerelease":true})";
  result=updates::evaluate({200,prerelease,updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed,"prerelease API response is not treated as a stable update");
  result=updates::evaluate({200,body,updates::Failure::None,0},"broken");combination();expect(result.state==updates::State::Failed,"invalid installed version is an error");
  result=updates::evaluate({0,{},updates::Failure::Offline,12029},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("internet")!=std::string::npos,"offline errors are explicit");
  result=updates::evaluate({0,{},updates::Failure::Timeout,12002},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("timed out")!=std::string::npos,"timeout errors are explicit");
  result=updates::evaluate({0,{},updates::Failure::SecureConnection,12175},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("secure")!=std::string::npos,"TLS errors are explicit");
  result=updates::evaluate({429,{},updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("rate limit")!=std::string::npos,"GitHub rate limits are explicit");
  result=updates::evaluate({401,{},updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("does not store")!=std::string::npos,"authentication failures do not request or imply embedded credentials");
  result=updates::evaluate({503,{},updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("temporarily unavailable")!=std::string::npos,"GitHub server failures are explicit");
  result=updates::evaluate({404,{},updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("Private repositories")!=std::string::npos,"private or unpublished repository response is explained");
  result=updates::evaluate({200,"not json",updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed,"invalid API JSON is never reported as current");
  result=updates::evaluate({200,std::string(65537,' '),updates::Failure::None,0},"1.2.0");combination();expect(result.state==updates::State::Failed&&result.error.find("oversized")!=std::string::npos,"oversized API responses are rejected");
  std::string foreign=body;const std::string official="https://github.com/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/tag/v1.2.0";auto at=foreign.find(official);if(at!=std::string::npos)foreign.replace(at,official.size(),"https://example.com/download");
  result=updates::evaluate({200,foreign,updates::Failure::None,0},"1.1.0");combination();expect(result.state==updates::State::Failed,"foreign release URLs are rejected");
 }
 block("timer engine, recovery, persistence");
 {Fixture f;f.advance(397);expect(f.e.snapshot().remaining==803,"elapsed countdown after UI stall");f.wall+=86400;expect(f.e.snapshot().remaining==803,"wall correction does not change work");}
 {Fixture f;f.advance(11.5);f.e.pause();f.advance(500);f.e.resume();f.advance(2.25);expect(f.e.snapshot().remaining==1186.25,"pause/resume precision");}
 {Fixture f;f.e.pause();Settings s;s.workMinutes=10;f.e.configure(s);f.e.reset();expect(f.e.snapshot().paused&&f.e.snapshot().remaining==600,"reset paused new duration");}
 {Fixture f;f.advance(1200);f.e.tick();f.e.tick();expect(f.reminders==1&&f.alarms==1,"one due event and alarm");expect(f.e.snapshot().phase==Phase::Break&&f.e.snapshot().remaining==20,"break started");f.advance(20);f.e.tick();expect(f.records.size()==1&&f.records[0].completed&&f.records[0].seconds==20,"break recorded");expect(f.e.snapshot().phase==Phase::Work&&f.e.snapshot().remaining==1200,"automatic next work cycle");}
 {Settings s;s.alarm=false;Fixture f(s);f.advance(1200);f.e.tick();expect(f.reminders==1&&f.alarms==0,"disabled alarm still reminds");}
 for(bool complete:{false,true}){Fixture f;f.e.takeBreak();f.advance(7);f.e.finish(complete);expect(f.records[0].completed==complete&&f.records[0].seconds==7,"early finish/skip duration");}
 for(int minutes:{1,3,5}){Fixture f;f.e.takeBreak();f.e.snooze(minutes);f.e.snooze(5);f.advance(minutes*60-1);f.e.tick();expect(f.reminders==1,"snooze delays");f.advance(1);f.e.tick();f.e.tick();expect(f.reminders==2&&f.records.empty(),"snooze one pending reminder no history");}
 for(int minutes:{0,-1,2,6}){Fixture f;f.e.takeBreak();f.e.snooze(minutes);expect(f.e.snapshot().phase==Phase::Break,"invalid snooze ignored");}
 {Settings s;s.snooze=false;Fixture f(s);f.e.takeBreak();f.e.snooze(1);expect(f.e.snapshot().phase==Phase::Break,"disabled snooze");}
 {Fixture f;f.advance(600);f.e.suspend(false);f.advance(1800);f.e.tick();expect(f.reminders==0,"no reminder asleep");f.e.wake();f.e.wake();expect(f.reminders==1&&f.e.snapshot().remaining==20,"one fresh reminder after long sleep");}
 {Fixture f;f.advance(100);f.e.suspend(false);f.advance(40);f.e.wake();expect(f.e.snapshot().remaining==1060,"short sleep deduction");}
 {Fixture f;f.e.pause();f.e.suspend(false);f.advance(3600);f.e.wake();expect(f.e.snapshot().paused&&f.e.snapshot().remaining==1200,"user pause preserved through sleep");}
 {Fixture f;f.advance(100);f.e.suspend(true);f.advance(3600);f.e.wake();expect(!f.e.snapshot().paused&&f.e.snapshot().remaining==1100,"lock auto pause");}
 {Settings s;s.pauseLocked=false;Fixture f(s);f.e.suspend(true);f.advance(5000);f.e.wake();expect(f.reminders==1,"unpaused lock recalculation");}
 {Fixture f;f.e.takeBreak();f.e.suspend(false);f.advance(1800);f.e.wake();expect(f.records.size()==1&&!f.records[0].completed&&f.e.snapshot().phase==Phase::Work,"expired sleeping break skipped");}
 {Fixture f;f.advance(60);f.e.pause();auto saved=f.e.save();f.advance(900);Fixture g;g.wall=f.wall;expect(g.e.restore(saved)&&g.e.snapshot().paused&&g.e.snapshot().remaining==1140,"paused restart restoration");}
 {Fixture f;f.advance(60);auto saved=f.e.save();f.advance(100);Fixture g;g.wall=f.wall;g.e.restore(saved);expect(g.e.snapshot().remaining==1040,"running restart deducts downtime");}
 {Fixture f;auto saved=f.e.save();f.advance(9999);Fixture g;g.wall=f.wall;g.e.restore(saved);g.e.tick();expect(g.reminders==0&&g.e.snapshot().remaining==1200,"stale restart no alarm");}
 {Fixture f;f.e.takeBreak();Fixture g;g.e.restore(f.e.save());expect(g.e.snapshot().phase==Phase::Work,"interrupted break fresh work");}
 {Fixture f;auto saved=f.e.save();saved.remaining=NAN;expect(!f.e.restore(saved),"NaN state rejected");saved=f.e.save();saved.remaining=20000;expect(!f.e.restore(saved),"inconsistent duration rejected");}
 {Fixture f;f.advance(86400);f.e.tick();expect(f.reminders==1&&f.e.snapshot().remaining==20,"no missed cycle backlog");}
 {Settings s;s.workMinutes=37;s.volume=30;s.theme=4;s.breakModeColors=false;s.selectedMonitor="DISPLAY2";s.customWorkAccent=true;s.workAccentColor=theme::rgb(59,130,246);s.customBreakAccent=true;s.breakAccentColor=theme::rgb(255,136,0);Settings d;expect(decodeSettings(encodeSettings(s),d)&&d.workMinutes==37&&d.volume==30&&d.theme==4&&!d.breakModeColors&&d.selectedMonitor=="DISPLAY2"&&d.customWorkAccent&&d.workAccentColor==s.workAccentColor&&d.customBreakAccent&&d.breakAccentColor==s.breakAccentColor,"theme, break-color and independent custom accents round trip");expect(decodeSettings("theme=0",d)&&d.theme==0&&d.breakModeColors&&!d.customWorkAccent&&!d.customBreakAccent,"older settings preserve theme choice and default custom accents");expect(decodeSettings("workMinutes=37\ncustomWorkAccent=1\nworkAccentColor=not-a-colour\ncustomBreakAccent=1\nbreakAccentColor=16777216",d)&&d.workMinutes==37&&!d.customWorkAccent&&!d.customBreakAccent,"invalid custom colours fall back without losing other preferences");expect(decodeSettings("theme=0\r\ncustomWorkAccent=1\r\nworkAccentColor=3900150\r\n",d)&&d.theme==0&&d.customWorkAccent&&d.workAccentColor==theme::rgb(59,130,246),"CRLF settings and custom RGB values load safely");expect(!decodeSettings("broken",d),"corrupted settings recovery");expect(!decodeSettings("alarm=2",d),"invalid Boolean rejected");expect(!decodeSettings("workMinutes=1x",d),"trailing number rejected");expect(!decodeSettings("",d),"empty settings rejected");expect(decodeSettings("workMinutes=-10\nbreakSeconds=999",d)&&d.workMinutes==1&&d.breakSeconds==300,"settings bounded");}
 {Fixture f;Saved d;expect(decodeTimer(encodeTimer(f.e.save()),d)&&d.remaining==1200,"timer round trip");expect(!decodeTimer("0 5 20 20 1 1791288000",d),"timer corrupt Boolean rejected");expect(!decodeTimer("0 0 20 20 1 1791288000 extra",d),"timer garbage rejected");}
 {std::vector<Record> in={{1791288000,true,20},{1791288000,false,7}},out;expect(decodeHistory(encodeHistory(in),out,1791288000)&&out.size()==2,"history round trip");expect(!decodeHistory("broken",out,1791288000),"history corruption recovery");expect(!decodeHistory("1791288000 1 -1",out,1791288000),"negative history rejected");}
 {std::vector<Record> r={{100,true,20},{100,false,2},{99,true,20},{98,true,20}};auto s=statistics(r,100,99,[](auto t){return int(t);});expect(s.todayCompleted==1&&s.todaySkipped==1&&s.completion==50,"today completion statistics");expect(s.weekCompleted==2&&s.streak==3&&s.totalCompleted==3,"week streak and total");auto empty=statistics({},100,99,[](auto t){return int(t);});expect(empty.totalCompleted==0&&empty.streak==0&&empty.completion==0,"empty history");expect(statistics({{99,true,20},{98,true,20}},100,99,[](auto t){return int(t);}).streak==2,"streak includes yesterday");}
 {std::vector<Record> r;for(int i=0;i<11000;++i)r.push_back({1791288000+i,true,20});std::vector<Record> out;expect(decodeHistory(encodeHistory(r),out,1791388000)&&out.size()==10000,"history retention bound");}
 {Fixture f;f.advance(100);f.e.suspend(false);f.advance(100);f.e.suspend(true);f.advance(3600);f.e.wake();expect(f.e.snapshot().remaining==1000,"sleep then lock applies lock pause");}
 {Fixture f;f.advance(100);f.e.suspend(true);f.advance(100);f.e.suspend(false);f.advance(3600);f.e.wake();expect(f.e.snapshot().remaining==1100,"lock then sleep preserves lock pause");}
 {Fixture f;f.e.takeBreak();f.e.pause();Fixture g;g.e.restore(f.e.save());expect(g.e.snapshot().paused&&g.e.snapshot().phase==Phase::Work,"paused interrupted break restores paused work");}
 {Fixture old;old.advance(480);Settings s;s.restore=false;Fixture fresh(s);expect(!fresh.e.restore(old.e.save()),"resume opt-out ignores previous countdown");expect(fresh.e.snapshot().phase==Phase::Work&&fresh.e.snapshot().remaining==1200&&!fresh.e.snapshot().paused,"resume opt-out starts fresh work");}

 block("break-completion alarm");
 // Break completion alarm: only a break that runs to zero announces completion, exactly once.
 {Fixture f;f.advance(1200);f.e.tick();auto breakCycle=f.e.snapshot().cycle;f.advance(19.9);f.e.tick();expect(f.completions==0,"no completion before the break reaches zero");f.advance(0.1);f.e.tick();f.e.tick();f.e.tick();expect(f.completions==1&&f.completionAlarms==1,"natural completion announced once");expect(f.completedCycle==breakCycle&&f.e.snapshot().cycle!=breakCycle,"completion identifies the finished break");expect(f.records.size()==1&&f.records[0].completed&&f.e.snapshot().phase==Phase::Work,"completion still recorded and work restarts");f.advance(5);f.e.tick();expect(f.completions==1,"no repeat while the next work interval runs");}
 {Settings s;s.alarm=false;Fixture f(s);f.e.takeBreak();f.advance(20);f.e.tick();expect(f.completions==1&&f.completionAlarms==0,"muted alarm reports completion without sound");}
 {Fixture f;f.e.takeBreak();f.advance(5);f.e.finish(false);expect(f.completions==0,"skip is not a completion alarm");}
 {Fixture f;f.e.takeBreak();f.advance(5);f.e.finish(true);f.advance(30);f.e.tick();expect(f.completions==0,"acknowledging a break early is not a natural completion");}
 {Fixture f;f.e.takeBreak();f.advance(5);f.e.reset();f.advance(30);f.e.tick();expect(f.completions==0,"reset during a break plays no completion alarm");}
 {Fixture f;f.e.takeBreak();f.advance(5);f.e.pause();f.advance(600);f.e.tick();expect(f.completions==0&&f.e.snapshot().phase==Phase::Break,"pause holds the break without completion");f.e.resume();f.advance(14.9);f.e.tick();expect(f.completions==0,"resumed break not yet complete");f.advance(0.1);f.e.tick();expect(f.completions==1,"resumed break completes once");}
 {Fixture f;f.e.takeBreak();f.e.snooze(1);f.advance(60);f.e.tick();expect(f.completions==0&&f.reminders==2,"snooze never announces completion");}
 {Fixture f;f.e.takeBreak();f.e.suspend(false);f.advance(1800);f.e.tick();f.e.wake();f.e.tick();expect(f.completions==0&&f.records.size()==1&&!f.records[0].completed,"break expiring during sleep is skipped without an alarm");}
 {Fixture f;f.e.takeBreak();f.e.suspend(true);f.advance(3600);f.e.tick();expect(f.completions==0,"no completion while locked");f.e.wake();expect(f.completions==0&&f.e.snapshot().phase==Phase::Break,"lock pause preserves the break without completion");f.advance(20);f.e.tick();expect(f.completions==1,"break completes after unlock");}
 {Fixture f;f.e.takeBreak();auto saved=f.e.save();f.advance(100);Fixture g;g.wall=f.wall;g.e.restore(saved);g.advance(100);g.e.tick();expect(g.completions==0,"restart recovery of an interrupted break plays no completion alarm");}
 {Fixture f;f.e.takeBreak();f.advance(20);f.e.tick();f.advance(1200);f.e.tick();auto second=f.e.snapshot().cycle;f.advance(20);f.e.tick();expect(f.completions==2&&f.completedCycle==second,"each completed break announces separately");}
 scheduleTests();
 block("scrolling model");
 // Scrolling model: wheel accumulation, bounded targets, short animation.
 {ScrollModel m;m.setRange(500);for(int i=0;i<10;++i)m.wheel(-12,60,false);expect(m.position()==60&&m.target()==60,"ten high-resolution wheel events accumulate exactly one notch");}
 {ScrollModel m;m.setRange(500);m.wheel(-120,60,false);m.wheel(-120,60,false);m.wheel(120,60,false);expect(m.target()==60,"reversing the wheel moves the target immediately");}
 {ScrollModel m(0.05);m.setRange(100);for(int i=0;i<7;++i)m.wheel(-40,3,false);expect(std::fabs(m.target()-7.0)<1e-9&&m.pixel()==7,"fractional row deltas accumulate across events");}
 {ScrollModel m;m.setRange(100);m.wheel(120,60,false);expect(m.position()==0,"wheel cannot scroll above the top");m.wheel(-120*10,60,false);expect(m.position()==100&&m.target()==100,"wheel cannot scroll beyond the bottom");}
 {ScrollModel m;m.setRange(1000);m.wheel(-120,60,true);expect(m.position()==0&&m.target()==60&&m.animating(),"animated wheel input updates the target at once");double last=0;int steps=0;bool monotonic=true;while(m.step(1.0/60)){if(m.position()<last||m.position()>60)monotonic=false;last=m.position();++steps;}expect(monotonic&&m.position()==60&&!m.animating(),"animation settles on the target without overshoot");expect(steps<=20,"one notch settles within about a third of a second");expect(!m.step(1.0/60)&&m.position()==60,"no movement after the target is reached");}
 {ScrollModel m;m.setRange(1000);m.wheel(-120,60,true);m.step(0.03);double before=m.position();m.wheel(-120,60,true);expect(m.target()==120&&m.position()==before,"new input retargets without restarting or queueing movement");m.wheel(120*5,60,true);expect(m.target()==0,"opposite input reverses direction immediately");while(m.step(1.0/60)){}expect(m.position()==0,"reversed animation ends at the new target");}
 {ScrollModel m;m.setRange(1000);m.jump(700);m.setRange(300);expect(m.position()==300&&m.target()==300,"shrinking content clamps position and target together");m.setRange(1000);expect(m.position()==300,"growing content keeps the position");}
 {ScrollModel m;m.setRange(1000);m.scrollTo(400,true);m.jump(250);expect(!m.animating()&&m.position()==250&&m.target()==250,"scrollbar dragging jumps without animation");m.rescale(1.5);expect(m.position()==375&&m.target()==375,"DPI change rescales position and target");}
 {ScrollModel m;m.setRange(0);m.wheel(-120,60,true);expect(!m.animating()&&m.position()==0,"content that fits cannot scroll");}

 geometryTests();
 if(argc>1&&std::string(argv[1])=="-v"){
  for(std::size_t i=0;i<accounts.size();++i){int end=i+1<accounts.size()?accounts[i+1].checksAtStart:checks;std::cout<<std::left<<std::setw(48)<<accounts[i].name<<std::right<<std::setw(7)<<end-accounts[i].checksAtStart<<" assertions"<<std::setw(7)<<accounts[i].combinations<<" combinations\n";}
 }
 std::cout<<"PASS: "<<checks<<" core assertions executed.\n";
}

// ============================================================================================================================
// Layout geometry. Every check is an invariant stated in device pixels; none recomputes a value with the helper under test.
// One assertion is made per parameter combination, so the counts printed by `-v` equal the number of combinations.
// ============================================================================================================================
namespace {
const int kDpis[]={96,120,144,168,192};
const double kTextScales[]={1.0,1.5,2.25};
unsigned lcg(unsigned&state){state=state*1664525u+1013904223u;return state>>8;}
// Half-up integer rounding of logical*dpi/96, written independently of geometry::scaled.
int halfUp(int logical,int dpi){return (logical*dpi*2+96)/192;}
}

void geometryTests(){
 // ---- DPI scaling ---------------------------------------------------------------------------------------------------------
 block("DPI scaling (geometry::scaled)");
 for(int dpi:kDpis)for(int logical:{0,1,6,17,24,33,200,210,640,2400}){combination();expect(geometry::scaled(logical,dpi)==halfUp(logical,dpi),"whole logical lengths scale by dpi/96 with half-up rounding");}
 combination();expect(geometry::scaled(7.5,96)==8&&geometry::scaled(0.4,96)==0&&geometry::scaled(33,192)==66,"fractional lengths round to nearest, 200% doubles exactly");
 for(int logical:{6,24,640})for(int i=1;i<5;++i){combination();expect(geometry::scaled(logical,kDpis[i])>=geometry::scaled(logical,kDpis[i-1]),"a larger DPI never yields a smaller length");}

 // ---- the Settings shell --------------------------------------------------------------------------------------------------
 block("Settings shell (geometry::contentColumn)");
 for(int dpi:kDpis){int previous=0;bool saturated=false;
  for(int logical=520;logical<=4000;logical+=53){
   const int client=halfUp(logical,dpi);auto c=geometry::contentColumn(client,dpi);combination();std::string problem;
   if(c.x<0||c.x+c.width>client)problem="the shell leaves the window (horizontal scrolling would be needed)";
   else if(c.width<=0)problem="shell width is not positive";
   else if(c.width>halfUp(640,dpi))problem="shell exceeds 640 logical px";
   else if(std::abs(c.x-(client-(c.x+c.width)))>1)problem="shell is not centred (left and right margins differ)";
   else if(c.x<halfUp(24,dpi)-1)problem="shell is closer to the window edge than the outer margin";
   else if(c.width<previous)problem="shell shrank although the window grew";
   else if(c.width<halfUp(640,dpi)&&std::abs(c.width-(client-2*halfUp(24,dpi)))>2)problem="below the maximum the shell must use all available width";
   previous=c.width;if(c.width==halfUp(640,dpi))saturated=true;
   expect(problem.empty(),problem.c_str());}
  combination();expect(saturated,"a wide window reaches the 640 logical px maximum");
  combination();{auto narrow=geometry::contentColumn(halfUp(520,dpi),dpi);expect(narrow.width>=halfUp(460,dpi),"the minimum window still gets a usable shell width");}}

 // ---- Timer ring -----------------------------------------------------------------------------------------------------------
  block("Timer ring sweep, countdown bounds and caption clearance");
 {const double remaining[]={1200,900,600,300,0};const double expected[]={0,0.25,0.5,0.75,1};
  for(int i=0;i<5;++i){Snapshot snapshot{Phase::Work,false,remaining[i],1200,1,false};combination();expect(std::fabs(snapshot.progress()-expected[i])<1e-9,"engine snapshot progress matches 0/25/50/75/100 percent remaining-time samples");}}
 {const double progress[]={0,0.25,0.5,0.75,1,-0.25,1.25};const double expected[]={0,90,180,270,360,0,360};
  for(int i=0;i<7;++i){combination();expect(std::fabs(geometry::timerProgressSweep(progress[i])-expected[i])<1e-9,"the ring sweep starts at 12 o'clock and covers 0/25/50/75/100 percent, clamped");}
  combination();expect(geometry::timerProgressStartDegrees==-90.0,"clockwise progress begins at 12 o'clock");}
 for(int dpi:kDpis)for(double textScale:kTextScales)for(int logical:{160,185,272}){
  int diameter=geometry::scaled(logical,dpi),inset=geometry::scaled(4,dpi),stroke=geometry::scaled(4,dpi),ringDiameter=diameter-2*inset;
   int countTop=diameter/3-inset,countHeight=diameter/3;
  auto fits=[&](int width,int top,int height){double radius=ringDiameter/2.0-stroke/2.0-1.0,center=ringDiameter/2.0;
   double farY=std::max(std::abs(double(top)-center),std::abs(double(top+height)-center));return width>0&&std::hypot(width/2.0+0.5,farY)<=radius+1e-9;};
   int countWidth=geometry::circleLabelWidth(ringDiameter,stroke,countTop,countHeight);
  combination();expect(fits(countWidth,countTop,countHeight),"countdown STATIC bounds stay inside the ring at supported DPIs and sizes");
    int headingHeight=geometry::timerHeaderHeight(dpi,textScale),captionOffset=geometry::timerHeaderCaptionOffset(dpi,textScale),ringTop=geometry::timerRingTopOffset(dpi);
    combination();expect(captionOffset+headingHeight<=ringTop,"full-width caption STATIC fits above the ring at supported DPIs and text scales");
    int ringLeft=geometry::scaled(100,dpi),statusDiameter=geometry::scaled(logical,dpi);auto status=geometry::timerStatusBounds(ringLeft,statusDiameter);
    combination();expect(status.left+status.width/2==ringLeft+statusDiameter/2,"Timer status is centred on the countdown circle at supported DPIs and ring sizes");}

 // ---- section navigation (segment rows) -----------------------------------------------------------------------------------
 block("section navigation (geometry::segmentRows)");
 {const int gap=6,minimum=40;unsigned seed=12345;int widestRows=0;bool sawEqual=false,sawWrapped=false;
  for(int set=0;set<24;++set){std::vector<int> natural;int count=3+int(lcg(seed)%5);for(int i=0;i<count;++i)natural.push_back(40+int(lcg(seed)%181));
   int lastRows=1<<30;
   for(int width=1200;width>=120;width-=17){   // shrinking window: rows may only increase
    auto segments=geometry::segmentRows(natural,50,width,gap,minimum);combination();std::string problem;
    std::vector<int> placed(natural.size(),0);int rows=0;for(auto&g:segments){if(g.index<0||g.index>=int(natural.size())){problem="bad segment index";break;}++placed[g.index];rows=std::max(rows,g.row+1);}
    for(int n:placed)if(n!=1)problem="a section button is missing or duplicated";
    for(int r=0;r<rows&&problem.empty();++r){std::vector<geometry::Segment> row;for(auto&g:segments)if(g.row==r)row.push_back(g);
     if(row.empty()){problem="a row is empty";break;}
     for(std::size_t k=0;k<row.size()&&problem.empty();++k){auto&g=row[k];
      if(g.x<50||g.x+g.width>50+width)problem="a segment leaves the column";
      else if(g.width<minimum)problem="a segment is narrower than the minimum";
      else if(g.width<std::min(natural[g.index],width))problem="a segment is narrower than its caption";
      else if(k>0&&g.x!=row[k-1].x+row[k-1].width+gap)problem="segments in a row are not separated by exactly the gap";}
     if(!problem.empty())break;
     if(row.size()>1&&row.back().x+row.back().width!=50+width)problem="a multi-segment row does not fill the column";
     if(row.size()==1&&(row[0].x!=50||row[0].width>width))problem="a lone segment is not left-aligned inside the column";}
    if(rows==1&&problem.empty()){sawEqual=true;int lo=1<<30,hi=0;bool equalMode=true;for(auto&g:segments){lo=std::min(lo,g.width);hi=std::max(hi,g.width);}
     int widest=*std::max_element(natural.begin(),natural.end());if((width-gap*(int(natural.size())-1))/int(natural.size())>=widest&&hi-lo>1)equalMode=false;if(!equalMode)problem="equal-width segments differ by more than a pixel";}
    if(rows>1)sawWrapped=true;
    if(problem.empty()&&rows>lastRows+0&&false)problem="";
    if(problem.empty()&&lastRows!=(1<<30)&&rows<lastRows)problem="row count decreased while the window shrank (unstable breakpoint)";
    lastRows=std::max(lastRows==(1<<30)?0:lastRows,rows);widestRows=std::max(widestRows,rows);
    expect(problem.empty(),problem.c_str());}}
  combination();expect(sawEqual&&sawWrapped&&widestRows>=2,"the sweep exercised both the one-row and the wrapped layouts");
  combination();expect(geometry::segmentRows({},0,300,gap,minimum).empty(),"no captions produce no segments");
  combination();{auto huge=geometry::segmentRows({400,400,400},0,300,gap,minimum);expect(huge.size()==3&&huge[0].row==0&&huge[1].row==1&&huge[2].row==2&&huge[2].width<=300,"captions wider than the column each get their own row without leaving it");}}

 // ---- primary tab bar: one row, never wraps, always fills the column
 block("primary tab bar (segmentRows, no wrap)");
 {unsigned seed=777;
  for(int set=0;set<20;++set){std::vector<int> natural;for(int i=0;i<3;++i)natural.push_back(60+int(lcg(seed)%220));
   for(int width=300;width<=1100;width+=19){auto tabs=geometry::segmentRows(natural,40,width,0,60,false);combination();std::string problem;
    if(tabs.size()!=3)problem="a tab is missing";
    for(std::size_t i=0;i<tabs.size()&&problem.empty();++i){if(tabs[i].row!=0)problem="the tab bar wrapped";else if(tabs[i].width<60)problem="a tab is narrower than the minimum";
     else if(i>0&&tabs[i].x!=tabs[i-1].x+tabs[i-1].width)problem="tabs are not edge to edge";}
    if(problem.empty()&&(tabs.front().x!=40||tabs.back().x+tabs.back().width!=40+width))problem="the tab bar does not span exactly the column (left and right edges must match the content column)";
    expect(problem.empty(),problem.c_str());}}}

 // ---- side-by-side decision -------------------------------------------------------------------------------------------------
 block("form mode decision (geometry::sideBySide)");
 for(int caption:{100,150,210,211,300}){bool seen=false;for(int width=300;width<=900;width+=7){bool now=geometry::sideBySide(width,caption,210,500);combination();expect(!(seen&&!now),"once the column is wide enough it never reverts to stacked as it grows");seen=seen||now;}
  combination();expect(geometry::sideBySide(900,caption,210,500)==(caption<=210),"a caption wider than the label column always stacks");}

 // ---- settings form placement ---------------------------------------------------------------------------------------------------
 block("settings form placement (geometry::layoutForm)");
 {using K=geometry::FormKind;
  struct Spec {K kind;int chars;bool sameRow,indent,spin,keep;};
  auto S=[](K k,int chars,bool same=false,bool indent=false,bool spin=false,bool keep=false){return Spec{k,chars,same,indent,spin,keep};};
  // A schedule period row: "From [start] to [end] [Remove] [Add period]" (labels keep with their fields; fields fit "00:00").
  auto period=[&](std::vector<Spec>&out,bool remove,bool add){out.push_back(S(K::Inline,4,false,true,false,true));out.push_back(S(K::Inline,9,true));out.push_back(S(K::Inline,2,true,false,false,true));out.push_back(S(K::Inline,9,true));
   if(remove){out.push_back(S(K::Inline,11,true));}
   if(add){out.push_back(S(K::Inline,14,true));}};
  std::vector<Spec> schedule={S(K::Heading,18),S(K::Check,25),S(K::Hint,150),S(K::Heading,11),S(K::Button,20),S(K::Button,21,true),S(K::Hint,50),S(K::Heading,12),S(K::Hint,230)};
  for(int d=0;d<7;++d){schedule.push_back(S(K::Check,9));int count=d==0?3:d==1?2:1;for(int i=0;i<count;++i)period(schedule,count>1,i==count-1&&count<3);}
  schedule.push_back(S(K::Heading,6));schedule.push_back(S(K::Plain,70));schedule.push_back(S(K::Hint,140));
  const std::vector<std::pair<const char*,std::vector<Spec>>> sections={
   {"Intervals",{S(K::Heading,24),S(K::Caption,23),S(K::Field,2,false,false,true),S(K::Caption,24),S(K::Field,2,false,false,true),S(K::Hint,66)}},
   {"Schedule",schedule},
   {"Alarm",{S(K::Heading,5),S(K::Check,13),S(K::Caption,11),S(K::Field,6),S(K::Caption,12),S(K::Slider,0),S(K::Value,3,true),S(K::Check,46),S(K::Button,13),S(K::Button,12,true)}},
   {"Reminders",{S(K::Heading,15),S(K::Check,21),S(K::Check,32),S(K::Heading,12),S(K::Caption,19),S(K::Field,12),S(K::Caption,17),S(K::Field,12),S(K::Caption,16),S(K::Field,12)}},
   {"General",{S(K::Heading,10),S(K::Caption,5),S(K::Field,18),S(K::Heading,9),S(K::Check,35),S(K::Check,18),S(K::Hint,55,false,true),S(K::Check,24),S(K::Hint,64,false,true),S(K::Check,41),S(K::Hint,80,false,true),S(K::Check,33),S(K::Hint,88,false,true)}},
   {"About",{S(K::Heading,5),S(K::Plain,18),S(K::Hint,30),S(K::Hint,80),S(K::Heading,13),S(K::Hint,58),S(K::Hint,62),S(K::Button,18)}}};
  int sideBySideCount=0,stackedCount=0;
  for(auto&named:sections)for(int dpi:kDpis)for(double ts:kTextScales){
   const int charW=geometry::scaled(7.2*ts,dpi),lineH=geometry::scaled(18.0*ts,dpi);bool wasSide=false,regressed=false;
   for(int logical=520;logical<=2400;logical+=60){
    const int client=halfUp(logical,dpi);auto column=geometry::contentColumn(client,dpi);const int inset=0,contentW=column.width;
    std::vector<geometry::FormItem> items;for(auto&sp:named.second){geometry::FormItem f;f.kind=sp.kind;f.textWidth=sp.chars*charW;int chars=sp.chars;f.textHeight=[=](int width){return ((chars*charW+std::max(1,width)-1)/std::max(1,width))*lineH+(chars==0?lineH:0);};f.sameRow=sp.sameRow;f.indent=sp.indent;f.spin=sp.spin;f.keep=sp.keep;if(sp.kind==K::Inline)f.width=sp.chars*charW+geometry::scaled(4,dpi);items.push_back(f);}
    auto form=geometry::layoutForm(items,contentW,inset,dpi,ts);combination();std::string problem;
    if(form.boxes.size()!=items.size())problem="a box is missing";
    // rectangles in device pixels; a field's spin button extends its right edge
    struct Rect {int l,t,r,b;};std::vector<Rect> rects;
    for(std::size_t i=0;i<items.size()&&problem.empty();++i){auto&b=form.boxes[i];rects.push_back({b.x,b.y,b.x+b.w+b.spinWidth,b.y+b.h});
     if(b.w<=0||b.h<=0)problem="a control has a non-positive size";
     else if(b.x<0||b.x+b.w+b.spinWidth>inset+contentW)problem="a control leaves the content column (horizontal scrolling would be needed)";
     else if(b.y<0)problem="a control starts above the pane";
     else if(b.y+b.h>form.height)problem="the form height does not cover its last control";}
    for(std::size_t i=0;i<rects.size()&&problem.empty();++i)for(std::size_t j=i+1;j<rects.size();++j){auto&a=rects[i];auto&c=rects[j];if(std::min(a.r,c.r)>std::max(a.l,c.l)&&std::min(a.b,c.b)>std::max(a.t,c.t)){problem="two controls overlap";break;}}
    // every field row (dropdown, slider with its value label) ends exactly at the column edge; number fields are the only narrow ones
    for(std::size_t i=0;i<items.size()&&problem.empty();++i){auto&item=items[i];if(item.kind==K::Caption&&i+1<items.size()&&!items[i+1].spin){std::size_t last=i+1;if(items[i+1].kind==K::Slider&&i+2<items.size()&&items[i+2].sameRow)last=i+2;auto&f=form.boxes[last];if(std::abs((f.x+f.w)-(inset+contentW))>1)problem="a field row does not end at the column edge (ragged right edge)";}}
    // structure: captions beside or above their fields, value labels beside sliders, rows flow downward without large gaps
    for(std::size_t i=0;i<items.size()&&problem.empty();++i){auto&item=items[i];auto&b=form.boxes[i];
     if(item.kind==K::Caption&&i+1<items.size()){auto&f=form.boxes[i+1];
      if(form.sideBySide){if(b.x+b.w>f.x||b.y!=f.y)problem="side-by-side caption is not left of its field on the same row";}
      else if(f.y<b.y+b.h)problem="stacked caption is not above its field";}
     if(item.kind==K::Value){auto&sl=form.boxes[i-1];if(b.x<sl.x+sl.w||b.y!=sl.y)problem="a value label is not beside its slider";}
     if(item.keep&&i+1<items.size()&&items[i+1].sameRow){auto&f=form.boxes[i+1];if(f.y!=b.y||f.x<b.x+b.w)problem="an inline label is separated from its field";}}
    // rows: a row is its leading item plus the fields/values/buttons that share it; rows must follow each other downward with small gaps
    {int previousBottom=-1;
     for(std::size_t i=0;i<items.size()&&problem.empty();++i){auto isFollower=[&](std::size_t n){return items[n].sameRow||items[n].kind==K::Field||items[n].kind==K::Slider;};
      if(isFollower(i)){continue;}
      int top=form.boxes[i].y,bottom=form.boxes[i].y+form.boxes[i].h;
      for(std::size_t j=i+1;j<items.size()&&isFollower(j);++j)bottom=std::max(bottom,form.boxes[j].y+form.boxes[j].h);
      if(previousBottom>=0){int gap=top-previousBottom;if(gap<0||gap>geometry::scaled(30,dpi))problem="vertical gap between rows is negative or larger than 30 logical px";}
      previousBottom=bottom;}}
    if(problem.empty()){if(wasSide&&!form.sideBySide)regressed=true;wasSide=wasSide||form.sideBySide;(form.sideBySide?sideBySideCount:stackedCount)++;}
    expect(problem.empty(),(std::string(named.first)+" dpi "+std::to_string(dpi)+" text "+std::to_string(ts)+" width "+std::to_string(logical)+": "+problem).c_str());}
   combination();expect(!regressed,"the form never switches back to stacked captions as the window grows");}
  combination();expect(sideBySideCount>0&&stackedCount>0,"the sweep exercised both side-by-side and stacked forms");}
}

// ============================================================================================================================
// Operating schedule. All instants are synthetic: MONDAY is 2026-10-05 00:00 in the fixture's calendar (zone 0 unless a test
// moves it), so every expectation is independent of the machine running the tests.
// ============================================================================================================================
namespace {
const std::int64_t MONDAY=daysFromCivil(2026,10,5)*86400;
std::int64_t when(int day,int h,int m,int s=0){return MONDAY+std::int64_t(day)*86400+h*3600+m*60+s;}
Schedule weekly(std::initializer_list<int> days,int start=540,int end=1020){Schedule s;s.enabled=true;s.days.fill(false);for(int d:days){s.days[d]=true;s.periods[d][0]=Period{start,end};}return s;}
Settings withSchedule(std::initializer_list<int> days,int start=540,int end=1020){Settings s;s.schedule=weekly(days,start,end);return s;}
bool opens(const Schedule&s,std::int64_t t){return s.allows(utcCalendar(t));}
// Mirrors the worker: one engine tick per second of elapsed time.
void run(Fixture&f,double seconds){for(double done=0;done<seconds;done+=1){f.advance(1);f.e.tick();}}
}

void scheduleTests(){
 const LocalClock utcClock=utcCalendar;
 block("operating schedule: calendar and calculations");
 expect(utcCalendar(MONDAY).weekday()==0&&utcCalendar(when(6,12,0)).weekday()==6&&utcCalendar(when(7,0,0)).weekday()==0,"calendar weekdays: Monday is 0 and Sunday 6");
 expect(utcCalendar(-1).weekday()==2&&utcCalendar(-1).minute==1439&&utcCalendar(-1).second==59,"calendar of an instant before 1970");
 expect(daysFromCivil(1970,1,1)==0&&daysFromCivil(2024,2,29)+1==daysFromCivil(2024,3,1)&&daysFromCivil(2025,1,1)-daysFromCivil(2024,1,1)==366,"civil day numbers");
 {Schedule off;expect(!off.enabled&&nextScheduleChange(off,when(0,12,0),utcClock)==0&&nextScheduleOpening(off,when(5,12,0),utcClock)==0&&nextScheduleClosing(off,when(1,12,0),utcClock)==0,"schedule off has no transitions");
  Fixture f({},when(5,3,0));run(f,1200);expect(!f.e.scheduled()&&f.e.scheduleOpen()&&!f.e.snapshot().held&&f.reminders==1,"schedule off: unrestricted legacy reminders on a Saturday night");}
 {auto s=weekly({0,1,2,3,4});
  expect(opens(s,when(1,12,0)),"active weekday and time");
  expect(!opens(s,when(5,12,0))&&!opens(s,when(6,12,0)),"inactive weekdays");
  expect(!opens(s,when(1,8,59,59)),"before opening");
  expect(opens(s,when(1,9,0)),"exactly at opening (start inclusive)");
  expect(opens(s,when(1,16,59))&&opens(s,when(1,16,59,59)),"one minute and one second before closing");
  expect(!opens(s,when(1,17,0)),"exactly at closing (end exclusive)");
  expect(!opens(s,when(1,17,0,1))&&!opens(s,when(1,17,1)),"immediately after closing");
  expect(nextScheduleChange(s,when(1,8,0),utcClock)==when(1,9,0)&&nextScheduleChange(s,when(1,9,0),utcClock)==when(1,17,0),"next opening and closing");
  expect(nextScheduleChange(s,when(1,8,59,59),utcClock)==when(1,9,0)&&nextScheduleChange(s,when(1,16,59,59),utcClock)==when(1,17,0),"transitions one second ahead");
  expect(nextScheduleChange(s,when(4,17,0),utcClock)==when(7,9,0),"Friday closing to Monday opening skips the weekend");
  expect(nextScheduleOpening(s,when(1,12,0),utcClock)==when(2,9,0)&&nextScheduleClosing(s,when(1,12,0),utcClock)==when(1,17,0)&&nextScheduleClosing(s,when(5,12,0),utcClock)==when(7,17,0),"next opening and closing from inside and outside hours");}
 {auto s=weekly({0},1320,120); // Monday 22:00-02:00; Tuesday is not selected
  expect(!opens(s,when(0,21,59,59))&&opens(s,when(0,22,0))&&opens(s,when(0,23,59,59)),"overnight period opens on its own day");
  expect(opens(s,when(1,0,0))&&opens(s,when(1,1,59,59)),"midnight: overnight period continues onto an unselected day");
  expect(!opens(s,when(1,2,0))&&!opens(s,when(1,12,0)),"the continuation ends at its end time and gives the unselected day nothing else");
  expect(!opens(s,when(0,1,0)),"an overnight period does not cover the early hours of its own start day");
  expect(nextScheduleChange(s,when(0,23,0),utcClock)==when(1,2,0),"no transition at midnight inside an overnight period");}
 {auto s=weekly({6},1320,120); // Sunday 22:00-02:00; Monday is not selected
  expect(opens(s,when(6,23,30))&&opens(s,when(7,1,0))&&opens(s,when(0,1,0))&&!opens(s,when(7,2,0)),"Sunday-to-Monday overnight period wraps the week");
  expect(nextScheduleChange(s,when(6,12,0),utcClock)==when(6,22,0)&&nextScheduleChange(s,when(6,22,0),utcClock)==when(7,2,0),"week wrap transitions");}
 {auto s=weekly({0,1});s.periods[0][0]=Period{1080,1440};s.periods[1][0]=Period{0,300};
  expect(opens(s,when(0,23,59,59))&&opens(s,when(1,0,0))&&nextScheduleChange(s,when(0,20,0),utcClock)==when(1,5,0),"periods touching at midnight are one period across the day boundary");}
 {auto s=weekly({0});s.counts[0]=2;s.periods[0][0]=Period{540,720};s.periods[0][1]=Period{780,1020};
  expect(opens(s,when(0,11,59))&&!opens(s,when(0,12,0))&&!opens(s,when(0,12,59,59))&&opens(s,when(0,13,0)),"multiple periods with a gap between them");
  expect(nextScheduleChange(s,when(0,10,0),utcClock)==when(0,12,0)&&nextScheduleChange(s,when(0,12,0),utcClock)==when(0,13,0)&&nextScheduleChange(s,when(0,13,0),utcClock)==when(0,17,0),"transitions around a gap");}
 {auto s=weekly({1});s.counts[1]=3;s.periods[1]={{Period{480,690},Period{750,960},Period{1080,1200}}};
  int open=0;for(int m=0;m<1440;++m)open+=opens(s,when(1,0,m));expect(open==210+210+120,"three periods cover exactly their minutes");}
 {auto s=weekly({0});s.counts[0]=2;s.periods[0][0]=Period{540,720};s.periods[0][1]=Period{720,1020};
  expect(opens(s,when(0,12,0))&&nextScheduleChange(s,when(0,10,0),utcClock)==when(0,17,0),"adjacent periods form one continuous period");}
 {auto s=weekly({0});s.counts[0]=3;s.periods[0]={{Period{540,780},Period{720,1020},Period{540,1020}}};
  expect(nextScheduleChange(s,when(0,8,0),utcClock)==when(0,9,0)&&nextScheduleChange(s,when(0,9,0),utcClock)==when(0,17,0),"overlapping and duplicate periods form one period");}
 {auto s=weekly({0,1,2,3,4,5,6},0,1440);bool always=true;for(int h=0;h<24*7;++h)always=always&&opens(s,when(0,h,59,59))&&opens(s,when(0,h,0));
  expect(always&&nextScheduleChange(s,when(2,12,0),utcClock)==0&&nextScheduleClosing(s,when(2,12,0),utcClock)==0,"every day all day: always open, no transitions");
  auto one=weekly({0},0,1440);expect(opens(one,when(0,0,0))&&opens(one,when(0,23,59,59))&&!opens(one,when(1,0,0))&&!opens(one,when(6,23,59,59)),"an all-day period covers exactly its day");
  expect(nextScheduleChange(one,when(6,12,0),utcClock)==when(7,0,0)&&nextScheduleChange(one,when(7,0,0),utcClock)==when(8,0,0),"all-day transitions at midnight");}
 {auto s=weekly({});bool never=true;for(int h=0;h<24*7;++h)never=never&&!opens(s,when(0,h,0));
  expect(never&&!s.anyDay()&&nextScheduleChange(s,when(0,12,0),utcClock)==0&&nextScheduleOpening(s,when(0,12,0),utcClock)==0,"no selected days: never open and no opening");
  Fixture f(withSchedule({}),when(1,12,0));run(f,3*3600);expect(f.e.snapshot().held&&f.reminders==0,"no selected days: no automatic reminders");}
 {auto s=weekly({2},0,1);expect(opens(s,when(2,0,0,59))&&!opens(s,when(2,0,1)),"earliest period 00:00-00:01");
  auto late=weekly({2},1439,1440);expect(!opens(late,when(2,23,58,59))&&opens(late,when(2,23,59))&&!opens(late,when(3,0,0)),"latest period 23:59-24:00");
  int m=-1;expect(parseClock("00:00",false,m)&&m==0&&parseClock("23:59",false,m)&&m==1439&&parseClock("24:00",true,m)&&m==1440,"earliest and latest typed times");
  Period p;expect(makePeriod(0,1440,p)&&p.length()==1440&&makePeriod(1439,0,p)&&p.end==1440&&p.length()==1&&makePeriod(1439,1438,p)&&p.length()==1439,"period bounds and lengths");}
 {int m=-1;
  expect(parseClock("9",false,m)&&m==540&&parseClock(" 9:30 ",false,m)&&m==570&&parseClock("0930",false,m)&&m==570&&parseClock("930",false,m)&&m==570&&parseClock("17.45",false,m)&&m==1065,"typed time formats");
  for(const char*bad:{"","  ","24:00","23:60","25","-1","9:5","9:300","12345","ab","1a:00","::","12:","+9"})expect(!parseClock(bad,false,m),"invalid typed start times rejected");
  expect(!parseClock("24:01",true,m)&&!parseClock("25:00",true,m)&&parseClock("00:00",true,m)&&m==0,"end times: 24:00 only exactly, 00:00 read as typed");
  expect(formatClock(0)=="00:00"&&formatClock(570)=="09:30"&&formatClock(1440)=="24:00","24-hour clock text");}
 {Period p;expect(!makePeriod(540,540,p)&&!makePeriod(0,0,p)&&!makePeriod(-1,60,p)&&!makePeriod(1440,60,p)&&!makePeriod(60,1441,p),"equal or out-of-range period values rejected (00:00 to 00:00 is not a whole day)");
  expect(makePeriod(600,0,p)&&p==Period{600,1440},"an end of 00:00 means midnight at the end of the day");
  expect(!Period{540,540}.valid()&&!Period{0,0}.valid()&&!Period{-5,60}.valid()&&!Period{60,0}.valid()&&Period{0,1440}.valid(),"period validity");}
 {Schedule s;s.counts={{0,5,-3,3,1,2,9}};s.periods[1][2]=Period{2000,10};s.validate();
  expect(s.counts[0]==1&&s.counts[1]==3&&s.counts[2]==1&&s.counts[6]==3&&s.periods[1][2]==Period{},"too many or too few periods are bounded to 1..3 and invalid periods replaced");
  LocalTime odd{0,5000,99};expect(s.allows(odd)==s.allows(LocalTime{0,1439,59})&&utcCalendar(when(3,10,0)).weekday()==3,"out-of-range clock fields are clamped and weekdays always fall in 0..6");}
 {const std::int64_t spring=when(6,1,0); // Sunday 01:00 UTC: local clocks go from 01:00 to 02:00
  LocalClock dst=[&](std::int64_t t){return utcCalendar(t+(t>=spring?3600:0));};
  auto every=weekly({0,1,2,3,4,5,6});std::int64_t opening=nextScheduleChange(every,when(5,20,0),dst);
  expect(opening==when(6,8,0)&&dst(opening).minute==540&&!every.allows(dst(opening-1)),"daylight saving start: opening at local 09:00 on a 23-hour day");
  auto gap=weekly({6},90,180); // Sunday 01:30-03:00 local; 01:30 never occurs that night
  expect(nextScheduleChange(gap,when(6,0,0),dst)==spring&&dst(spring).minute==120,"a period starting in the skipped hour opens when the clock jumps");
  expect(nextScheduleChange(gap,spring,dst)==when(6,2,0),"and closes at local 03:00");}
 {const std::int64_t fall=when(6,1,0); // Sunday 01:00 UTC: local 02:00 becomes 01:00 again
  LocalClock dst=[&](std::int64_t t){return utcCalendar(t+(t<fall?3600:0));};
  auto early=weekly({6},0,90); // Sunday 00:00-01:30 local
  std::int64_t closing=nextScheduleChange(early,when(5,23,30),dst);
  expect(closing==when(6,0,30),"daylight saving end: closes at the first local 01:30");
  std::int64_t again=nextScheduleChange(early,closing,dst);
  expect(again==fall&&dst(fall).minute==60,"the repeated local hour reopens the period as the clock shows it");
  expect(nextScheduleChange(early,again,dst)==when(6,1,30),"and closes at the second local 01:30");
  auto every=weekly({0,1,2,3,4,5,6});expect(nextScheduleChange(every,when(5,20,0),dst)==when(6,9,0)&&dst(when(6,9,0)).minute==540,"daylight saving end: opening at local 09:00 on a 25-hour day");}

 block("operating schedule: countdown");
 const Settings workdays=withSchedule({0,1,2,3,4});
 {Fixture f(workdays,when(1,9,0));expect(!f.e.snapshot().held&&f.e.scheduleOpen()&&f.e.scheduled(),"open at a weekday opening");run(f,1199);expect(f.reminders==0,"no reminder before the work interval");run(f,1);
  expect(f.reminders==1&&f.alarms==1&&f.e.snapshot().phase==Phase::Break,"normal automatic reminder within the schedule");run(f,20);expect(f.completions==1&&f.completionAlarms==1&&f.records.size()==1&&f.records[0].completed,"break completion inside hours unchanged");}
 {Fixture f(workdays,when(1,18,0));auto before=f.e.snapshot();run(f,3*3600);auto after=f.e.snapshot();
  expect(before.held&&after.held&&after.remaining==1200&&after.remaining==before.remaining&&f.reminders==0&&f.records.empty(),"countdown stands still outside the schedule");}
 {Fixture f(workdays,when(1,16,30));run(f,1200);expect(f.reminders==1,"reminder inside hours before closing");run(f,20);expect(f.records.size()==1&&f.records[0].completed,"a break completed before closing stays in history");
  run(f,double(when(1,17,0)-f.wall));expect(f.e.snapshot().held&&f.e.snapshot().remaining==1200&&f.e.snapshot().phase==Phase::Work,"closing holds a fresh, still interval");
  run(f,double(when(2,9,0)-f.wall));auto open=f.e.snapshot();expect(!open.held&&open.remaining==1200&&f.reminders==1,"next opening starts a full work interval with no immediate reminder");
  run(f,1199);expect(f.reminders==1,"no reminder before a full interval after opening");run(f,1);expect(f.reminders==2&&f.dueAt.back()==when(2,9,20),"first reminder a full interval after the opening");}
 {Fixture f(workdays,when(0,0,0));run(f,7*86400.0);bool inside=true;for(auto t:f.dueAt)inside=inside&&opens(workdays.schedule,t);
  int perDay=0;for(int t=1200;t<8*3600;t+=1220)++perDay; // 20 min work + 20 s break, from 09:00 until 17:00
  expect(inside,"over a week every automatic reminder falls inside operating hours");
  expect(int(f.dueAt.size())==5*perDay,"a week gives exactly the in-hours reminders: no backlog, nothing at weekends");
  bool fresh=true;for(auto t:f.dueAt){auto l=utcCalendar(t);if(l.minute>=540&&l.minute<560)fresh=false;}expect(fresh,"no reminder in the first full interval after each 09:00 opening");}
 {Fixture f(workdays,when(1,16,40));run(f,1200);expect(f.wall==when(1,17,0)&&f.reminders==0&&f.e.snapshot().held,"a countdown due exactly at closing produces no reminder (schedule checked first)");}
 {Fixture f(workdays,when(1,16,50));run(f,60);f.e.pause();double kept=f.e.snapshot().remaining;run(f,double(when(2,10,0)-f.wall));auto s=f.e.snapshot();
  expect(kept==1140&&s.paused&&!s.held&&s.remaining==kept&&f.reminders==0,"manual pause before closing survives the closing and the next opening");
  f.e.resume();expect(!f.e.snapshot().paused&&f.e.snapshot().remaining==kept,"resume inside hours continues the paused time");run(f,kept);expect(f.reminders==1,"then reminds normally");}
 {Fixture f(workdays,when(1,16,50));f.e.pause();run(f,3600);f.e.resume();auto s=f.e.snapshot();
  expect(!s.paused&&s.held&&s.remaining==1200,"resume outside hours does not bypass the schedule");run(f,3600);expect(f.reminders==0&&f.e.snapshot().remaining==1200,"no countdown after resuming outside hours");
  run(f,double(when(2,9,0)-f.wall));run(f,1200);expect(f.reminders==1&&f.dueAt[0]==when(2,9,20),"the next opening starts the countdown");}
 {Fixture f(workdays,when(1,20,0));f.e.pause();f.e.pause();f.e.resume();f.e.resume();expect(f.e.snapshot().held&&!f.e.snapshot().paused&&f.reminders==0,"repeated pause and resume outside hours stay held");}
 {Fixture f({},when(1,10,0));run(f,300);f.e.configure(workdays);auto s=f.e.snapshot();expect(!s.held&&s.remaining==900,"enabling the schedule inside hours keeps the running countdown");
  Fixture g({},when(1,20,0));run(g,300);g.e.configure(workdays);expect(g.e.snapshot().held&&g.e.snapshot().remaining==1200,"enabling the schedule outside hours holds at once");run(g,3600);expect(g.reminders==0,"and no reminder follows");}
 {Fixture f(workdays,when(1,20,0));run(f,600);f.e.configure(Settings{});expect(!f.e.snapshot().held&&!f.e.scheduled(),"disabling the schedule while inactive releases the hold");run(f,1199);expect(f.reminders==0,"with a fresh interval");run(f,1);expect(f.reminders==1,"then legacy reminders resume");}
 {Fixture f(workdays,when(1,16,0));run(f,300);auto later=workdays;later.schedule.periods[1][0]=Period{540,1080};f.e.configure(later);
  expect(!f.e.snapshot().held&&f.e.snapshot().remaining==900,"changing hours that stay open keeps the countdown");
  auto earlier=workdays;earlier.schedule.periods[1][0]=Period{540,960};f.e.configure(earlier);expect(f.e.snapshot().held&&f.reminders==0,"changing hours so that now is closed holds immediately");}
 {Fixture f(workdays,when(1,16,39,50));run(f,1200);expect(f.reminders==1&&f.e.snapshot().phase==Phase::Break,"automatic break starts just before closing");run(f,10);auto s=f.e.snapshot();
  expect(f.wall==when(1,17,0)&&s.phase==Phase::Work&&s.held&&f.records.empty()&&f.completions==0,"closing cancels the automatic break without history or completion alarm");run(f,3600);expect(f.reminders==1,"no further reminder after closing");}
 {Fixture f(workdays,when(1,16,39,50));run(f,1200);f.e.pause();run(f,30);auto s=f.e.snapshot();expect(s.phase==Phase::Work&&s.paused&&s.held&&f.records.empty(),"a paused automatic break is cancelled at closing and the pause is kept");}
 {Fixture f(workdays,when(1,16,35));run(f,1200);f.e.snooze(5);expect(f.e.snapshot().phase==Phase::Snooze,"snoozed before closing");run(f,double(when(1,17,0)-f.wall));auto s=f.e.snapshot();
  expect(s.phase==Phase::Work&&s.held&&f.records.empty(),"closing cancels a pending snooze without history");run(f,3600);expect(f.reminders==1,"the snoozed reminder never fires outside hours");}
 {Fixture f(workdays,when(1,16,40));run(f,1199);for(int i=0;i<5;++i){f.wall=when(1,17,0)+i%2;f.e.tick();f.e.tick();f.wall=when(1,16,59,59);f.e.tick();}
  expect(f.reminders==0&&f.records.empty(),"flapping across a closing never produces a reminder");}
 {Fixture f(workdays,when(1,20,0));f.e.takeBreak();auto s=f.e.snapshot();expect(s.phase==Phase::Break&&s.held&&f.reminders==1&&f.alarms==0,"an explicit manual break outside hours opens without the alarm");
  f.e.snooze(5);expect(f.e.snapshot().phase==Phase::Break,"snooze is unavailable outside hours");
  run(f,20);expect(f.completions==1&&f.completionAlarms==0&&f.records.size()==1&&f.records[0].completed,"it completes and is recorded, without a completion alarm outside hours");
  expect(f.e.snapshot().held&&f.e.snapshot().phase==Phase::Work,"automatic operation stays held afterwards");run(f,3*3600);expect(f.reminders==1,"a manual break starts no out-of-hours cycle");}
 {Fixture f(workdays,when(1,20,0));f.e.takeBreak();run(f,5);f.e.finish(false);expect(f.records.size()==1&&!f.records[0].completed&&f.e.snapshot().held,"skipping a manual break outside hours records the skip and stays held");}
 {Fixture f(workdays,when(1,16,59,55));f.e.takeBreak();expect(f.alarms==1,"a manual break inside hours plays the alarm as before");run(f,5);expect(f.e.snapshot().phase==Phase::Break&&f.e.snapshot().held,"a manual break continues past the closing");
  run(f,15);expect(f.completions==1&&f.completionAlarms==0&&f.records.size()==1&&f.records[0].completed,"it completes without a completion alarm after closing");run(f,3600);expect(f.reminders==1&&f.e.snapshot().held,"and automatic operation stays held");}
 {Fixture f(workdays,when(1,8,59,50));f.e.takeBreak();run(f,10);expect(!f.e.snapshot().held&&f.e.snapshot().phase==Phase::Break,"a manual break keeps running across the opening");
  run(f,10);expect(f.completions==1&&f.completionAlarms==1,"and completes inside hours with the completion alarm");run(f,1199);expect(f.reminders==1,"no reminder before the next full interval");run(f,1);expect(f.reminders==2,"the first automatic reminder follows a full interval");}
 {Fixture f(workdays,when(1,10,0));run(f,1200);run(f,20);run(f,1200);expect(f.reminders==2&&f.completions==1,"consecutive cycles inside hours are unchanged");}

 block("operating schedule: recovery and lifecycle");
 {Fixture f(workdays,when(1,10,0));run(f,60);auto saved=f.e.save();Fixture g(workdays,when(1,10,1,40));expect(g.e.restore(saved)&&g.e.snapshot().remaining==1100&&!g.e.snapshot().held,"restart within the same operating period deducts downtime as before");}
 {auto split=workdays;split.schedule.counts[1]=2;split.schedule.periods[1][0]=Period{540,720};split.schedule.periods[1][1]=Period{721,1020};
  Fixture f(split,when(1,11,50));run(f,200);auto saved=f.e.save();
  Fixture g(split,when(1,12,1,30));g.e.restore(saved);g.e.tick();expect(g.e.snapshot().remaining==1200&&!g.e.snapshot().held&&g.reminders==0,"restart after a scheduled gap does not subtract time outside operating hours");
  Fixture h(split,when(1,11,58,20));h.e.restore(saved);expect(h.e.snapshot().remaining==700,"restart inside the same period deducts downtime");}
 {Fixture f(workdays,when(1,16,50));run(f,300);auto saved=f.e.save();Fixture g(workdays,when(2,9,30));expect(g.e.restore(saved),"restart across an inactive period is accepted");g.e.tick();auto s=g.e.snapshot();
  expect(s.remaining==1200&&!s.held&&!s.paused&&g.reminders==0,"restart across an inactive period starts a fresh interval without a reminder");}
 {Fixture f(workdays,when(1,16,0));run(f,100);auto saved=f.e.save();Fixture g(workdays,when(1,20,0));expect(g.e.restore(saved),"restart while inactive is accepted");auto s=g.e.snapshot();g.e.tick();
  expect(s.held&&s.remaining==1200&&g.reminders==0,"restart while inactive holds a fresh interval");}
 {Fixture f(workdays,when(1,16,0));run(f,60);f.e.pause();auto saved=f.e.save();
  Fixture g(workdays,when(1,20,0));g.e.restore(saved);expect(g.e.snapshot().paused&&g.e.snapshot().held&&g.e.snapshot().remaining==1140,"paused restart while inactive keeps the paused time");
  Fixture h(workdays,when(2,10,0));h.e.restore(saved);expect(h.e.snapshot().paused&&!h.e.snapshot().held&&h.e.snapshot().remaining==1140,"paused restart after a gap keeps the paused time");}
 {Settings manual=workdays;manual.autoStart=false;Fixture f(workdays,when(1,16,0));auto saved=f.e.save();Fixture g(manual,when(2,10,0));g.e.restore(saved);expect(g.e.snapshot().paused&&g.e.snapshot().remaining==1200,"restart after a gap respects automatic start being off");}
 {Fixture f(workdays,when(1,10,0));f.e.takeBreak();auto saved=f.e.save();Fixture g(workdays,when(1,10,0,30));g.e.restore(saved);g.e.tick();
  expect(g.e.snapshot().phase==Phase::Work&&g.reminders==0&&g.completions==0,"an interrupted break is not replayed with a startup alarm");
  Fixture h(workdays,when(1,22,0));h.e.restore(saved);h.e.tick();expect(h.e.snapshot().held&&h.reminders==0,"nor outside operating hours");}
 {Settings off=workdays;off.restore=false;Fixture f(workdays,when(1,10,0));Fixture g(off,when(1,10,5));expect(!g.e.restore(f.e.save()),"resume opt-out still ignores the checkpoint");}
 {Fixture f(workdays,when(1,8,0));f.e.suspend(false);f.advance(5400);f.e.wake();auto s=f.e.snapshot();expect(!s.held&&s.remaining==1200&&f.reminders==0,"sleep across an opening: fresh interval from waking, no reminder");
  run(f,1200);expect(f.reminders==1&&f.dueAt[0]==when(1,9,50),"the first reminder follows a full interval from waking");}
 {Fixture f(workdays,when(1,16,30));run(f,600);f.e.suspend(false);f.advance(5400);f.e.wake();f.e.wake();auto s=f.e.snapshot();
  expect(s.held&&s.remaining==1200&&f.reminders==0&&f.records.empty(),"sleep across a closing holds without a reminder");}
 {Fixture f(workdays,when(1,16,0));run(f,600);f.e.suspend(false);f.advance(18*3600);f.e.wake();auto s=f.e.snapshot();
  expect(!s.held&&s.remaining==1200&&f.reminders==0,"waking after an extended inactive period starts fresh instead of reminding at once");}
 {Fixture f(workdays,when(1,16,39,50));run(f,1200);f.e.suspend(false);f.advance(3600);f.e.wake();
  expect(f.records.empty()&&f.completions==0&&f.e.snapshot().held&&f.e.snapshot().phase==Phase::Work,"an automatic break asleep across a closing ends without history");}
 {Fixture f(workdays,when(1,20,0));f.e.takeBreak();f.e.suspend(false);f.advance(5);f.e.wake();run(f,15);expect(f.completions==1&&f.completionAlarms==0&&f.e.snapshot().held,"a short sleep inside a manual out-of-hours break keeps it, silently");}
 {Fixture f(workdays,when(1,20,0));f.e.suspend(false);f.advance(3600);f.e.wake();expect(f.e.snapshot().held&&f.e.snapshot().remaining==1200&&f.reminders==0,"sleep while inactive deducts nothing");}
 {Fixture f(workdays,when(1,10,0));run(f,100);f.e.suspend(true);f.advance(1800);f.e.wake();expect(f.e.snapshot().remaining==1100&&!f.e.snapshot().held,"lock pause within operating hours as before");
  Fixture g(workdays,when(1,16,30));run(g,100);g.e.suspend(true);g.advance(3600);g.e.wake();expect(g.e.snapshot().held&&g.reminders==0,"lock across a closing: held, no reminder");}
 {auto unpaused=workdays;unpaused.pauseLocked=false;Fixture f(unpaused,when(1,10,0));run(f,100);f.e.suspend(true);f.advance(1800);f.e.wake();expect(f.reminders==1,"lock without lock pause counts inside hours as before (one reminder)");
  Fixture g(unpaused,when(1,16,50));g.e.suspend(true);g.advance(1800);g.e.wake();expect(g.reminders==0&&g.e.snapshot().held,"lock without lock pause across a closing: no reminder");}
 {Fixture f(workdays,when(1,16,50));f.e.suspend(false);f.advance(300);f.e.suspend(true);f.advance(1800);f.e.wake();expect(f.e.snapshot().held&&f.reminders==0,"nested sleep then lock across a closing");
  Fixture g(workdays,when(1,10,0));run(g,100);g.e.suspend(false);g.advance(100);g.e.suspend(true);g.advance(3600);g.e.wake();expect(g.e.snapshot().remaining==1000,"nested sleep then lock inside hours applies lock pause as before");
  Fixture h(workdays,when(1,8,50));h.e.suspend(true);h.advance(300);h.e.suspend(false);h.advance(1800);h.e.wake();expect(!h.e.snapshot().held&&h.e.snapshot().remaining==1200&&h.reminders==0,"nested lock then sleep across an opening starts fresh");}
 {Fixture f(workdays,when(1,8,0));f.e.suspend(false);f.advance(7200);f.e.wake();f.e.wake();f.e.wake();run(f,1200);expect(f.reminders==1,"repeated wake and unlock messages give one countdown and one reminder");}
 {Fixture f(workdays,when(1,10,0));run(f,300);f.wall+=8*3600;f.e.tick();expect(f.e.snapshot().held&&f.reminders==0,"a forward clock change past closing holds without a burst of reminders");
  Fixture g(workdays,when(1,10,0));run(g,300);g.wall+=2*3600;g.e.tick();expect(!g.e.snapshot().held&&g.e.snapshot().remaining==900,"a forward clock change within hours leaves the monotonic countdown alone");}
 {Fixture f(workdays,when(1,17,5));expect(f.e.snapshot().held,"held after closing");f.wall-=600;f.e.tick();auto s=f.e.snapshot();
  expect(!s.held&&s.remaining==1200&&f.reminders==0,"a backward clock change into hours opens with a fresh interval and no immediate reminder");run(f,300);expect(f.e.snapshot().held&&f.reminders==0,"and closes again at the repeated closing without a reminder");}
 {Fixture f(workdays,when(1,15,0));run(f,60);f.zone=3*3600;f.e.tick();expect(f.e.snapshot().held,"moving to a time zone where it is after closing holds");
  f.zone=-3*3600;f.e.tick();expect(!f.e.snapshot().held&&f.e.snapshot().remaining==1200&&f.reminders==0,"moving back opens with a fresh interval");}
 {auto every=withSchedule({0,1,2,3,4,5,6});Fixture f(every,when(5,20,0));f.dstFrom=when(6,1,0);f.dstTo=when(60,0,0);run(f,double(when(6,7,59,59)-f.wall));expect(f.e.snapshot().held,"still closed one second before local 09:00 after the clocks go forward");
  run(f,1);expect(!f.e.snapshot().held,"opens at local 09:00");run(f,1200);expect(f.reminders==1&&f.dueAt[0]==when(6,8,20),"first reminder a full interval after the local opening");}
 {auto every=withSchedule({0,1,2,3,4,5,6});Fixture f(every,when(5,21,0));f.dstFrom=when(-30,0,0);f.dstTo=when(6,1,0); // local time is UTC+1 until Sunday 01:00 UTC
  run(f,double(when(6,8,59,59)-f.wall));expect(f.e.snapshot().held,"daylight saving end: still closed before local 09:00");run(f,1);expect(!f.e.snapshot().held,"opens at local 09:00 on the long day");}

 block("operating schedule: persistence");
 {Settings s;s.schedule.enabled=true;s.schedule.days={{true,false,true,false,true,true,false}};s.schedule.counts[0]=2;s.schedule.periods[0][0]=Period{540,720};s.schedule.periods[0][1]=Period{780,1440};
  s.schedule.periods[5][0]=Period{1320,120};s.schedule.counts[6]=3;s.schedule.periods[6]={{Period{0,1440},Period{60,61},Period{1439,1438}}};
  Settings d;auto text=encodeSettings(s);expect(decodeSettings(text,d)&&d.schedule.enabled&&d.schedule.sameHours(s.schedule),"schedule round trip");
  expect(text.find("schedule=1\n")!=std::string::npos&&text.find("scheduleMonday2=13002400\n")!=std::string::npos&&text.find("scheduleSaturday1=22000200\n")!=std::string::npos&&text.find("scheduleTuesday=0\n")!=std::string::npos,"documented settings format");
  // Earlier versions read every value except selectedMonitor as a whole integer and skip unknown keys.
  bool integers=true;std::istringstream lines(text);std::string line;while(std::getline(lines,line)){auto eq=line.find('=');if(line.substr(0,eq)=="selectedMonitor")continue;auto value=line.substr(eq+1);try{std::size_t used=0;std::stoi(value,&used);integers=integers&&used==value.size();}catch(...){integers=false;}}
  expect(integers,"every schedule value is an integer, so an earlier version can still load the file");
  expect(decodeSettings(encodeSettings(d),d)&&encodeSettings(d)==text,"encoding is deterministic");}
 {Settings d;expect(decodeSettings("workMinutes=25\nbreakSeconds=30\nalarm=1\nselectedMonitor=DISPLAY1\n",d)&&d.workMinutes==25&&d.selectedMonitor=="DISPLAY1"&&!d.schedule.enabled&&d.schedule.sameHours(Schedule{}),"settings from 1.0.6 load with the schedule off and default hours");
  Settings fresh;expect(!fresh.schedule.enabled&&fresh.schedule.days[0]&&fresh.schedule.days[4]&&!fresh.schedule.days[5]&&!fresh.schedule.days[6]&&fresh.schedule.periods[0][0]==Period{540,1020},"default schedule: off, weekdays 09:00-17:00");
  Settings back;expect(decodeSettings(encodeSettings(Settings{}),back)&&!back.schedule.enabled&&back.schedule.sameHours(Schedule{}),"defaults round trip");}
 {Settings d;for(const char*bad:{"schedule=2","scheduleMonday=5","scheduleMonday1=09000900","scheduleMonday1=00000000","scheduleMonday1=25001700","scheduleMonday1=09601700","scheduleMonday1=24000100","scheduleMonday1=09002401","scheduleMonday1=-1","scheduleMonday1=123456789","scheduleMonday1=09:00-17:00","scheduleMonday1="})
   expect(!decodeSettings(std::string("workMinutes=20\n")+bad+"\n",d),"corrupt or invalid schedule values are rejected");
  expect(decodeSettings("scheduleMonday1=00002400\nscheduleMonday1=08001200\n",d)&&d.schedule.counts[0]==1&&d.schedule.periods[0][0]==Period{480,720},"the last duplicate line wins");
  expect(decodeSettings("scheduleMonday3=13001700\nscheduleMonday1=08001200\nscheduleMonday4=18001900\nscheduleFunday=1\nscheduleMonday9=1\n",d)&&d.schedule.counts[0]==2&&d.schedule.periods[0][0]==Period{480,720}&&d.schedule.periods[0][1]==Period{780,1020},"periods keep their order; extra period numbers and unknown day names are ignored");
  expect(decodeSettings("scheduleTuesday1=10000000\n",d)&&d.schedule.periods[1][0]==Period{600,1440},"a stored end of 0000 means midnight");}
 {Settings s;s.schedule=weekly({2,3},600,900);s.workMinutes=30;Settings reset{};expect(!reset.schedule.enabled&&reset.schedule.sameHours(Schedule{})&&!s.schedule.sameHours(reset.schedule),"reset all settings restores the default, disabled schedule");
  Fixture f(s,when(2,20,0));expect(f.e.snapshot().held,"held under the custom schedule");f.e.configure(reset);expect(!f.e.snapshot().held&&f.e.snapshot().remaining==1200,"resetting settings releases the hold with the default interval");}
 {Fixture f(workdays,when(1,20,0));Saved d;expect(decodeTimer(encodeTimer(f.e.save()),d)&&d.remaining==1200&&d.phase==0&&!d.paused,"timer checkpoint format unchanged while held");
  Saved legacy;expect(decodeTimer("0 0 600 1200 7 1791288000",legacy)&&legacy.remaining==600,"existing timer checkpoints still parse");}
 {Schedule a=Schedule::preset(false),b=Schedule::preset(true);expect(a.days[4]&&!a.days[5]&&b.days[5]&&b.days[6]&&a.periods[6][0]==Period{540,1020}&&!a.enabled&&!b.enabled,"quick setup presets");}
}
