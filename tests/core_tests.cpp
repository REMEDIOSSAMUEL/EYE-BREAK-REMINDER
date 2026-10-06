#include "../src/core.hpp"
#include <iostream>
#include <cstdlib>
using namespace eye;
static int checks=0;
void expect(bool condition,const char* name){if(!condition){std::cerr<<"FAIL: "<<name<<'\n';std::exit(1);}++checks;}
struct Fixture {double mono=0;std::int64_t wall=1791288000;Settings s;Engine e;int reminders=0,alarms=0;std::vector<Record>records;
 Fixture(Settings value={}):s(value),e(s,[this]{return mono;},[this]{return wall;}){e.due=[this](auto,bool sound){++reminders;if(sound)++alarms;};e.ended=[this](Record r){records.push_back(r);};}
 void advance(double seconds){mono+=seconds;wall+=static_cast<std::int64_t>(seconds);} };
int main(){
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
 std::cout<<"PASS: "<<checks<<" core assertions executed.\n";
}
