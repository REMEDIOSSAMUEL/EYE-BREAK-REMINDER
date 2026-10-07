#include "../src/core.hpp"
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
struct Fixture {double mono=0;std::int64_t wall=1791288000;Settings s;Engine e;int reminders=0,alarms=0,completions=0,completionAlarms=0;std::uint64_t completedCycle=0;std::vector<Record>records;
 Fixture(Settings value={}):s(value),e(s,[this]{return mono;},[this]{return wall;}){e.due=[this](auto,bool sound){++reminders;if(sound)++alarms;};e.ended=[this](Record r){records.push_back(r);};e.breakCompleted=[this](std::uint64_t cycle,bool sound){++completions;completedCycle=cycle;if(sound)++completionAlarms;};}
 void advance(double seconds){mono+=seconds;wall+=static_cast<std::int64_t>(seconds);} };
void geometryTests();
int main(int argc,char**argv){
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
 {Settings s;s.workMinutes=37;s.volume=30;s.theme=2;s.selectedMonitor="DISPLAY2";Settings d;expect(decodeSettings(encodeSettings(s),d)&&d.workMinutes==37&&d.volume==30&&d.theme==2&&d.selectedMonitor=="DISPLAY2","settings round trip");expect(!decodeSettings("broken",d),"corrupted settings recovery");expect(!decodeSettings("alarm=2",d),"invalid Boolean rejected");expect(!decodeSettings("workMinutes=1x",d),"trailing number rejected");expect(!decodeSettings("",d),"empty settings rejected");expect(decodeSettings("workMinutes=-10\nbreakSeconds=999",d)&&d.workMinutes==1&&d.breakSeconds==300,"settings bounded");}
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
  struct Spec {K kind;int chars;bool sameRow,indent,spin;};
  auto S=[](K k,int chars,bool same=false,bool indent=false,bool spin=false){return Spec{k,chars,same,indent,spin};};
  const std::vector<std::pair<const char*,std::vector<Spec>>> sections={
   {"Intervals",{S(K::Heading,24),S(K::Caption,23),S(K::Field,2,false,false,true),S(K::Caption,24),S(K::Field,2,false,false,true),S(K::Hint,66)}},
   {"Alarm",{S(K::Heading,5),S(K::Check,13),S(K::Caption,11),S(K::Field,6),S(K::Caption,12),S(K::Slider,0),S(K::Value,3,true),S(K::Check,46),S(K::Button,13),S(K::Button,12,true)}},
   {"Reminders",{S(K::Heading,15),S(K::Check,21),S(K::Check,32),S(K::Heading,12),S(K::Caption,19),S(K::Field,12),S(K::Caption,17),S(K::Field,12),S(K::Caption,16),S(K::Field,12)}},
   {"General",{S(K::Heading,10),S(K::Caption,5),S(K::Field,18),S(K::Heading,9),S(K::Check,35),S(K::Check,18),S(K::Hint,55,false,true),S(K::Check,24),S(K::Hint,64,false,true),S(K::Check,41),S(K::Hint,80,false,true),S(K::Check,33),S(K::Hint,88,false,true)}},
   {"About",{S(K::Heading,5),S(K::Plain,18),S(K::Hint,30),S(K::Hint,80),S(K::Heading,13),S(K::Hint,58),S(K::Hint,62),S(K::Button,18)}}};
  int sideBySideCount=0,stackedCount=0;
  for(auto&named:sections)for(int dpi:kDpis)for(double ts:kTextScales){
   const int charW=geometry::scaled(7.2*ts,dpi),lineH=geometry::scaled(18.0*ts,dpi);bool wasSide=false,regressed=false;
   for(int logical=520;logical<=2400;logical+=60){
    const int client=halfUp(logical,dpi);auto column=geometry::contentColumn(client,dpi);const int inset=0,contentW=column.width;
    std::vector<geometry::FormItem> items;for(auto&sp:named.second){geometry::FormItem f;f.kind=sp.kind;f.textWidth=sp.chars*charW;int chars=sp.chars;f.textHeight=[=](int width){return ((chars*charW+std::max(1,width)-1)/std::max(1,width))*lineH+(chars==0?lineH:0);};f.sameRow=sp.sameRow;f.indent=sp.indent;f.spin=sp.spin;items.push_back(f);}
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
     if(item.kind==K::Value){auto&sl=form.boxes[i-1];if(b.x<sl.x+sl.w||b.y!=sl.y)problem="a value label is not beside its slider";}}
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
