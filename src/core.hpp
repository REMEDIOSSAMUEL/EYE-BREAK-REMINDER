#pragma once
#include <algorithm>
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
struct Settings {
    int workMinutes=20, breakSeconds=20, sound=0, volume=55, mode=0, monitor=0, theme=0;
    bool alarm=true, repeat=false, notifications=true, snooze=true, autoStart=true;
    bool startup=false, tray=true, restore=true, pauseLocked=true, history=true, trayExplained=false;
    int width=820, height=720, x=-32000, y=-32000;
    std::string selectedMonitor;
    void validate() {
        workMinutes=std::clamp(workMinutes,1,180); breakSeconds=std::clamp(breakSeconds,5,300);
        sound=std::clamp(sound,0,4); volume=std::clamp(volume,0,100); mode=std::clamp(mode,0,2);
        monitor=std::clamp(monitor,0,2); theme=std::clamp(theme,0,2);
        width=std::clamp(width,520,2560); height=std::clamp(height,480,2160);
        if(selectedMonitor.size()>128) selectedMonitor.clear();
    }
};
struct Record { std::int64_t at=0; bool completed=false; double seconds=0; };
struct Saved { int phase=0; bool paused=false; double remaining=1200, duration=1200; std::uint64_t cycle=1; std::int64_t at=0; };
struct Snapshot { Phase phase; bool paused; double remaining, duration; std::uint64_t cycle;
    double progress() const {return std::clamp(1-remaining/duration,0.0,1.0);} };
class Engine {
    Settings settings;
    std::function<double()> monotonic;
    std::function<std::int64_t()> utc;
    Phase phase=Phase::Work;
    bool paused=false, suspended=false, lockPause=false;
    double remaining=1200, duration=1200, anchor=0;
    std::int64_t suspendedAt=0;
    std::uint64_t cycle=1;
    double nowRemaining() const {return paused||suspended?remaining:std::max(0.0,remaining-(monotonic()-anchor));}
    void begin(Phase next,double seconds,bool stop=false) {
        phase=next; remaining=duration=seconds; paused=stop; anchor=monotonic(); ++cycle;
        if(changed)changed();
    }
    void record(bool completed) {if(ended)ended({utc(),completed,std::clamp(duration-nowRemaining(),0.0,duration)});}
    void startBreak() {begin(Phase::Break,settings.breakSeconds);if(due)due(cycle,settings.alarm);}
    // Only a countdown that reaches zero while running announces completion. The callback follows begin(), so the
    // finished break's UI teardown has already happened and the completion alarm is not stopped by it.
    void completeBreak() {auto finished=cycle;finish(true);if(breakCompleted)breakCompleted(finished,settings.alarm);}
public:
    std::function<void()> changed;
    std::function<void(std::uint64_t,bool)> due;
    std::function<void(std::uint64_t,bool)> breakCompleted;
    std::function<void(Record)> ended;
    Engine(Settings s,std::function<double()> mono,std::function<std::int64_t()> wall):settings(s),monotonic(std::move(mono)),utc(std::move(wall)) {
        settings.validate(); remaining=duration=settings.workMinutes*60; paused=!settings.autoStart;anchor=monotonic();
    }
    void configure(Settings s) {s.validate();settings=s;}
    Snapshot snapshot()const{return{phase,paused||lockPause,nowRemaining(),duration,cycle};}
    bool isSuspended()const{return suspended;}
    void tick() {if(paused||suspended||nowRemaining()>0)return;if(phase==Phase::Break)completeBreak();else startBreak();}
    void pause() {if(paused)return;remaining=nowRemaining();anchor=monotonic();paused=true;if(changed)changed();}
    void resume() {if(!paused)return;anchor=monotonic();paused=false;if(changed)changed();tick();}
    void reset() {if(phase==Phase::Break)record(false);begin(Phase::Work,settings.workMinutes*60,paused);}
    void takeBreak() {if(phase!=Phase::Break&&!suspended)startBreak();}
    void finish(bool completed) {if(phase!=Phase::Break)return;record(completed);begin(Phase::Work,settings.workMinutes*60);}
    void snooze(int minutes) {if(phase==Phase::Break&&settings.snooze&&(minutes==1||minutes==3||minutes==5))begin(Phase::Snooze,minutes*60);}
    void suspend(bool locked) {
        if(suspended){
            if(locked&&settings.pauseLocked&&!lockPause){if(!paused)remaining=std::max(0.0,remaining-double(std::max<std::int64_t>(0,utc()-suspendedAt)));lockPause=true;suspendedAt=utc();if(changed)changed();}
            return;
        }
        remaining=nowRemaining();anchor=monotonic();lockPause=locked&&settings.pauseLocked;suspendedAt=utc();suspended=true;if(changed)changed();
    }
    void wake() {
        if(!suspended)return;
        double absent=double(std::max<std::int64_t>(0,utc()-suspendedAt));suspended=false;anchor=monotonic();
        if(!paused&&!lockPause){remaining=std::max(0.0,remaining-absent);if(remaining<=0&&phase==Phase::Break){record(false);begin(Phase::Work,settings.workMinutes*60);}}
        lockPause=false;if(changed)changed();tick();
    }
    Saved save()const{return{int(phase),paused,nowRemaining(),duration,cycle,utc()};}
    bool restore(const Saved& s) {
        if(!settings.restore||s.phase<0||s.phase>2||!std::isfinite(s.remaining)||!std::isfinite(s.duration)||s.duration<=0||s.duration>10800||s.remaining<0||s.remaining>s.duration||!s.cycle||s.at<1577836800)return false;
        double elapsed=double(std::max<std::int64_t>(0,utc()-s.at));
        if(s.phase==int(Phase::Break)||(!s.paused&&elapsed>=s.remaining)){begin(Phase::Work,settings.workMinutes*60,s.paused||!settings.autoStart);return true;}
        phase=Phase(s.phase);paused=s.paused;remaining=std::max(0.0,s.remaining-(paused?0:elapsed));duration=s.duration;cycle=s.cycle;anchor=monotonic();if(changed)changed();return true;
    }
};
inline std::string encodeSettings(const Settings&s) {
    std::ostringstream o;
#define EYE_WRITE(field) o<<#field<<'='<<s.field<<'\n'
    EYE_WRITE(workMinutes);EYE_WRITE(breakSeconds);EYE_WRITE(sound);EYE_WRITE(volume);EYE_WRITE(mode);EYE_WRITE(monitor);EYE_WRITE(theme);
    EYE_WRITE(alarm);EYE_WRITE(repeat);EYE_WRITE(notifications);EYE_WRITE(snooze);EYE_WRITE(autoStart);EYE_WRITE(startup);EYE_WRITE(tray);
    EYE_WRITE(restore);EYE_WRITE(pauseLocked);EYE_WRITE(history);EYE_WRITE(trayExplained);EYE_WRITE(width);EYE_WRITE(height);EYE_WRITE(x);EYE_WRITE(y);EYE_WRITE(selectedMonitor);
#undef EYE_WRITE
    return o.str();
}
inline bool decodeSettings(const std::string& text, Settings& out) {
    if(text.size()>65536)return false;
    Settings s;std::istringstream input(text);std::string line;int count=0;
    while(std::getline(input,line)) {
        if(line.empty())continue;
        auto eq=line.find('=');if(eq==std::string::npos)return false;
        auto key=line.substr(0,eq),value=line.substr(eq+1);++count;
        if(key=="selectedMonitor"){if(value.size()>128||value.find('\r')!=std::string::npos)return false;s.selectedMonitor=value;continue;}
        int n=0;try{std::size_t used=0;n=std::stoi(value,&used);if(used!=value.size())return false;}catch(...){return false;}
#define EYE_INT(field) if(key==#field){s.field=n;continue;}
#define EYE_BOOL(field) if(key==#field){if(n!=0&&n!=1)return false;s.field=n!=0;continue;}
        EYE_INT(workMinutes);EYE_INT(breakSeconds);EYE_INT(sound);EYE_INT(volume);EYE_INT(mode);EYE_INT(monitor);EYE_INT(theme);EYE_INT(width);EYE_INT(height);EYE_INT(x);EYE_INT(y);
        EYE_BOOL(alarm);EYE_BOOL(repeat);EYE_BOOL(notifications);EYE_BOOL(snooze);EYE_BOOL(autoStart);EYE_BOOL(startup);EYE_BOOL(tray);EYE_BOOL(restore);EYE_BOOL(pauseLocked);EYE_BOOL(history);EYE_BOOL(trayExplained);
#undef EYE_INT
#undef EYE_BOOL
    }
    if(count==0)return false;
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
// value label on the same row; buttons flow left to right and wrap when they no longer fit.
enum class FormKind {Plain,Heading,Caption,Hint,Check,Field,Slider,Value,Button};
struct FormItem {FormKind kind=FormKind::Plain;int textWidth=0;std::function<int(int)> textHeight;bool sameRow=false,indent=false,spin=false;};
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
