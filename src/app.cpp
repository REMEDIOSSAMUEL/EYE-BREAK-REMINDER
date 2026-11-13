#include "windows_services.hpp"
#include "theme.hpp"
#include "update_checker.hpp"
#include <array>
#include <atomic>
#include <commdlg.h>
#include <mutex>
#include <thread>
#include <winhttp.h>
#include <winver.h>
using namespace eye;
using namespace eye::win;
namespace {
constexpr wchar_t CLASS[]=L"EyeBreakReminder.Native";
constexpr wchar_t BREAK_CLASS[]=L"EyeBreakReminder.Break";
constexpr wchar_t TRAY_MENU_CLASS[]=L"EyeBreakReminder.TrayMenu";
constexpr UINT TRAY_MESSAGE=WM_APP+1, ENGINE_MESSAGE=WM_APP+2, PREVIEW_REFRESH=WM_APP+5, RESIZE_REFRESH=WM_APP+6;
constexpr UINT UPDATE_RESULT=WM_APP+7;
constexpr int NAV_TIMER=10,NAV_HISTORY=11,NAV_SETTINGS=12,PAUSE=20,RESET=21,TAKE_BREAK=22,COMPLETE=23,SKIP=24,SNOOZE1=25,SNOOZE3=26,SNOOZE5=27;
constexpr int COUNTDOWN=40,TIMER_STATE=41,COUNT_CAPTION=42,BREAK_TITLE=43,BREAK_INSTRUCTION=44,BREAK_GUIDANCE=45,HISTORY_TOGGLE=30,CLEAR_HISTORY=31,ALARM_TOGGLE=32,WORK=100,BREAK_SECONDS=101,SOUND=102,VOLUME=103,MODE=104,MONITOR=105,THEME=106,REPEAT=107,NOTIFY=108,SNOOZE=109,AUTO_START=110,STARTUP=111,TRAY=112,RESTORE=113,PAUSE_LOCK=114,SELECT_MONITOR=115,PREVIEW=116,STOP_AUDIO=117,RESET_SETTINGS=118,VOLUME_VALUE=119;
constexpr int SCHEDULE_TOGGLE=120,PRESET_WEEKDAYS=121,PRESET_EVERYDAY=122,SCHEDULE_STATUS=123,BREAK_COLORS=124;
constexpr int WORK_ACCENT_SWATCH=125,BREAK_ACCENT_SWATCH=126,CHOOSE_WORK_ACCENT=127,CHOOSE_BREAK_ACCENT=128,RESET_ACCENT_COLORS=129;
constexpr int UPDATE_CHECK=160,UPDATE_OPEN=161,UPDATE_STATUS=162,UPDATE_LATEST=163,UPDATE_INSTALLED=164;
// Weekly hours: one check box per day (DAY_BASE + day). Period controls are PERIOD_BASE + day*10 + period*3 + {0 start, 1 end,
// 2 Remove}; PERIOD_BASE + day*10 + 9 is the day's Add period button.
constexpr int DAY_BASE=280,PERIOD_BASE=300,PERIOD_END=PERIOD_BASE+70;
constexpr UINT_PTR RENDER=1,CHECKPOINT=2,SCROLL=3;
constexpr int SECTION_BASE=130,SECTION_COUNT=6,SCHEDULE_SECTION=1;
constexpr const wchar_t* DAY_NAMES[7]={L"Monday",L"Tuesday",L"Wednesday",L"Thursday",L"Friday",L"Saturday",L"Sunday"};
// Settings controls are typed so one layout engine can place them on a shared grid.
using Kind=geometry::FormKind;
// `group` is the weekday a schedule row control belongs to (-1 otherwise); `keep` wraps an inline label with the field after it.
struct Control {HWND handle{};int id=0;int page=0;Kind kind=Kind::Plain;HWND buddySpin{};int x=0,y=0,w=0,h=0,spinWidth=0,rowHeight=0,section=0,group=-1;bool sameRow=false,indent=false,keep=false;};
struct Placement {HWND handle{};int x=0,y=0,w=0,h=0;};
struct TimerGeometry {int left=0,top=0,diameter=0,ringX=0,ringY=0,ringDiameter=0;};
struct TimerPresentation {std::wstring countdown,caption,status;double progress=0;};
struct Colors {
 COLORREF background{},surface{},hover{},foreground{},secondary{},line{};
 COLORREF defaultWorkAccent{},defaultBreakAccent{},workAccent{},breakAccent{},focus{},workButtonText{},breakButtonText{};
 bool dark=true,contrast=false,systemContrast=false;
};
struct UpdateDispatch {std::mutex mutex;HWND target{};bool alive=true;};
struct UpdateMessage {updates::CheckResult result;};
class Application {
public:
 HINSTANCE instance{};HWND main{},breakWindow{},trayMenuOwner{};HICON icon{};HFONT normalFont{},headingFont{},tabFont{},smallFont{},titleFont{},countFont{},breakFont{},breakTitleFont{},breakCountFont{};int countSize=0;HBRUSH backgroundBrush{},surfaceBrush{};
 Settings settings;std::unique_ptr<Engine> engine;std::unique_ptr<Audio> audio;std::vector<Record> history;
 std::array<COLORREF,16> pickerCustomColors{{RGB(255,255,255),RGB(192,192,192),RGB(128,128,128),RGB(0,0,0),RGB(255,0,0),RGB(128,0,0),RGB(255,255,0),RGB(128,128,0),RGB(0,255,0),RGB(0,128,0),RGB(0,255,255),RGB(0,128,128),RGB(0,0,255),RGB(0,0,128),RGB(255,0,255),RGB(128,0,128)}};
 std::vector<Control> controls;std::array<HWND,3> nav{};std::array<HWND,SECTION_COUNT> sectionNav{};int settingsSection=0,buildSection=0;HWND historyList{},settingsPane{};std::vector<Monitor> displays;
 Colors colors;std::wstring directory;UINT dpi=96;double textScale=1;bool hidden=false,locked=false,sleeping=false,quitting=false,quietBreak=false,loading=false,trayAdded=false,dirtySettings=false,saveWarned=false;
 int page=0,settingsHeight=0,breakHeight=0,settingsApplied=INT_MIN,breakApplied=INT_MIN,historyApplied=0;TimerPresentation timerPresentation;UINT renderTimerInterval=0;std::uint64_t notifiedCycle=0,alarmedCycle=0;NOTIFYICONDATAW trayData{};
 ScrollModel settingsScroller,breakScroller,historyScroller{0.05};std::vector<Placement> breakItems;bool scrollTimer=false,previewRefreshPosted=false;double scrollClock=0;
 HANDLE dueEvent{},stopEvent{};HANDLE worker{};volatile LONG interactiveResize=0,resizeRefreshPosted=0,resizeVisualInterval=250;UINT activateMessage=RegisterWindowMessageW(L"EyeBreakReminder.Activate.Native.1");UINT quitMessage=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");UINT explorerMessage=RegisterWindowMessageW(L"TaskbarCreated");
 double deadline=0;CRITICAL_SECTION deadlineLock{};RECT normalBounds{};bool haveNormalBounds=false,breakSnooze=false;
 // Dynamic Annotation gives schedule fields full accessible names ("Monday, period 1, start time") beyond their short visible labels.
 IAccPropServices* accessibility{};std::vector<HWND> annotated;
 std::atomic_bool updateCheckActive{false};std::shared_ptr<UpdateDispatch> updateDispatch;std::wstring updateReleaseUrl;
 static Application* app;
 int px(double value)const{return geometry::scaled(value,int(dpi));}
 int fontHeight(int points)const{return -int(std::round(points*dpi/72.0*textScale));}
 static COLORREF nativeColor(theme::Color value){return RGB((value>>16)&0xffu,(value>>8)&0xffu,value&0xffu);}
 static theme::Color themeColor(COLORREF value){return theme::rgb(GetRValue(value),GetGValue(value),GetBValue(value));}
 bool breakAccentActive()const{return engine&&engine->snapshot().phase==Phase::Break&&(settings.breakModeColors||colors.contrast);}
 COLORREF activeAccent()const{return breakAccentActive()?colors.breakAccent:colors.workAccent;}
 COLORREF activeButtonText()const{return breakAccentActive()?colors.breakButtonText:colors.workButtonText;}
 COLORREF accentSwatch(bool work)const{
  if(work)return settings.customWorkAccent?nativeColor(settings.workAccentColor):colors.defaultWorkAccent;
  return settings.customBreakAccent?nativeColor(settings.breakAccentColor):colors.defaultBreakAccent;
 }
 COLORREF accentText()const{return colors.contrast?activeAccent():nativeColor(theme::readableAccentText(themeColor(activeAccent()),themeColor(colors.background)));}
 void updateAccentSwatches(){
  for(auto item:{std::pair<int,bool>{WORK_ACCENT_SWATCH,true},std::pair<int,bool>{BREAK_ACCENT_SWATCH,false}}){
   if(HWND h=find(item.first)){SetWindowTextW(h,wide(theme::formatHexColor(themeColor(accentSwatch(item.second)))).c_str());InvalidateRect(h,nullptr,TRUE);}
  }
 }
 void error(const wchar_t* message){inform(main,L"Eye Break Reminder",message,colors.dark,colors.systemContrast);}
 LRESULT drawButton(NMHDR* notification){
  if(!notification||notification->code!=NM_CUSTOMDRAW||colors.systemContrast)return CDRF_DODEFAULT;
  HWND button=notification->hwndFrom;wchar_t name[32]{};GetClassNameW(button,name,32);if(wcscmp(name,TRACKBAR_CLASSW)==0)return drawTrackbar(reinterpret_cast<NMCUSTOMDRAW*>(notification));if(wcscmp(name,L"Button")!=0)return CDRF_DODEFAULT;
  auto draw=reinterpret_cast<NMCUSTOMDRAW*>(notification);if(draw->dwDrawStage!=CDDS_PREPAINT)return CDRF_DODEFAULT;
  DWORD style=DWORD(GetWindowLongPtrW(button,GWL_STYLE)),type=style&BS_TYPEMASK;
  bool checkbox=type==BS_AUTOCHECKBOX;
  if(!checkbox&&type!=BS_PUSHBUTTON&&type!=BS_DEFPUSHBUTTON&&!(style&BS_PUSHLIKE))return CDRF_DODEFAULT;
  int id=GetDlgCtrlID(button),scale=int(GetDpiForWindow(button));auto bpx=[&](int n){return std::max(1,n*scale/96);};
  bool enabled=IsWindowEnabled(button)!=FALSE,pressed=(draw->uItemState&CDIS_SELECTED)!=0;
  bool selected=SendMessageW(button,BM_GETCHECK,0,0)==BST_CHECKED,hot=(draw->uItemState&CDIS_HOT)!=0;
  if((id>=NAV_TIMER&&id<=NAV_SETTINGS)||(id>=SECTION_BASE&&id<SECTION_BASE+SECTION_COUNT))return drawTab(draw,button,id,selected,hot,pressed);
  bool primary=id==TAKE_BREAK||id==COMPLETE||id==PREVIEW;
  COLORREF accent=activeAccent();
  COLORREF fill=checkbox?colors.background:(primary?accent:(selected||hot?colors.hover:colors.surface));
  COLORREF ink=enabled?colors.foreground:colors.secondary;if(primary)ink=activeButtonText();
  COLORREF buttonBorder=primary||selected?accent:colors.line;
  if(primary&&theme::contrastRatio(themeColor(accent),themeColor(colors.background))<3.0)buttonBorder=colors.foreground;
  if(pressed&&!checkbox)fill=colors.hover;
  if(pressed&&primary)ink=colors.foreground;
  RECT rect=draw->rc;FillRect(draw->hdc,&rect,backgroundBrush);
  auto rgba=[](COLORREF color){return Gdiplus::Color(255,GetRValue(color),GetGValue(color),GetBValue(color));};
  {Gdiplus::Graphics graphics(draw->hdc);graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
   if(checkbox){int side=bpx(18),x=rect.left+bpx(2),y=rect.top+(rect.bottom-rect.top-side)/2;Gdiplus::SolidBrush brush(rgba(selected?accent:colors.surface));Gdiplus::Pen border(rgba(selected?accent:colors.line),float(bpx(colors.contrast?2:1)));graphics.FillRectangle(&brush,x,y,side,side);graphics.DrawRectangle(&border,x,y,side,side);
    if(selected){Gdiplus::Pen tick(rgba(activeButtonText()),float(bpx(2)));graphics.DrawLine(&tick,x+bpx(4),y+bpx(9),x+bpx(8),y+bpx(13));graphics.DrawLine(&tick,x+bpx(8),y+bpx(13),x+bpx(15),y+bpx(5));}
   }else{
    float x=float(rect.left+1),y=float(rect.top+1),w=float(rect.right-rect.left-2),h=float(rect.bottom-rect.top-2);
    if(w>0&&h>0){Gdiplus::SolidBrush brush(rgba(fill));Gdiplus::Pen border(rgba(buttonBorder),float(bpx(colors.contrast?2:1)));
     if(colors.contrast){graphics.FillRectangle(&brush,x,y,w,h);graphics.DrawRectangle(&border,x,y,w,h);}
     else {float corner=float(std::min(bpx(14),int(h)));Gdiplus::GraphicsPath path;path.AddArc(x,y,corner,corner,180,90);path.AddArc(x+w-corner,y,corner,corner,270,90);path.AddArc(x+w-corner,y+h-corner,corner,corner,0,90);path.AddArc(x,y+h-corner,corner,corner,90,90);path.CloseFigure();graphics.FillPath(&brush,&path);graphics.DrawPath(&border,&path);}}
   }
  }
  wchar_t caption[512]{};GetWindowTextW(button,caption,512);RECT textRect=rect;InflateRect(&textRect,-bpx(12),-bpx(4));if(checkbox)textRect.left=rect.left+bpx(32);
  int saved=SaveDC(draw->hdc);SelectObject(draw->hdc,reinterpret_cast<HFONT>(SendMessageW(button,WM_GETFONT,0,0)));
  UINT flags=checkbox?DT_LEFT|DT_WORDBREAK:DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS;LRESULT cues=SendMessageW(button,WM_QUERYUISTATE,0,0);if(cues&UISF_HIDEACCEL)flags|=DT_HIDEPREFIX;
  if(checkbox){RECT measured=textRect;DrawTextW(draw->hdc,caption,-1,&measured,flags|DT_CALCRECT);int height=measured.bottom-measured.top;textRect.top=rect.top+std::max(0,(int(rect.bottom-rect.top)-height)/2);}
  SetTextColor(draw->hdc,ink);SetBkMode(draw->hdc,TRANSPARENT);DrawTextW(draw->hdc,caption,-1,&textRect,flags);
  if((draw->uItemState&CDIS_FOCUS)&&!(cues&UISF_HIDEFOCUS)){RECT focus=rect;InflateRect(&focus,-bpx(4),-bpx(4));if(colors.contrast){HPEN pen=CreatePen(PS_SOLID,bpx(2),colors.focus);HGDIOBJ oldPen=SelectObject(draw->hdc,pen),oldBrush=SelectObject(draw->hdc,GetStockObject(NULL_BRUSH));Rectangle(draw->hdc,focus.left,focus.top,focus.right,focus.bottom);SelectObject(draw->hdc,oldBrush);SelectObject(draw->hdc,oldPen);DeleteObject(pen);}else DrawFocusRect(draw->hdc,&focus);}RestoreDC(draw->hdc,saved);
  return CDRF_SKIPDEFAULT;
 }
 bool drawAccentSwatch(DRAWITEMSTRUCT*draw){
  if(!draw||draw->CtlType!=ODT_STATIC||(draw->CtlID!=WORK_ACCENT_SWATCH&&draw->CtlID!=BREAK_ACCENT_SWATCH))return false;
  const bool work=draw->CtlID==WORK_ACCENT_SWATCH;RECT rect=draw->rcItem;FillRect(draw->hDC,&rect,backgroundBrush);
  const int side=std::max(1,std::min(px(36),int(rect.bottom-rect.top)-px(8)));
  RECT sample{rect.left+px(2),rect.top+(int(rect.bottom-rect.top)-side)/2,rect.left+px(2)+side,rect.top+(int(rect.bottom-rect.top)+side)/2};
  HBRUSH fill=CreateSolidBrush(accentSwatch(work));if(fill){FillRect(draw->hDC,&sample,fill);DeleteObject(fill);}
  HBRUSH border=CreateSolidBrush(colors.line);if(border){FrameRect(draw->hDC,&sample,border);DeleteObject(border);}
  RECT text{sample.right+px(8),rect.top,rect.right-px(2),rect.bottom};
  int saved=SaveDC(draw->hDC);SelectObject(draw->hDC,normalFont);SetTextColor(draw->hDC,colors.foreground);SetBkMode(draw->hDC,TRANSPARENT);
  const std::wstring value=wide(theme::formatHexColor(themeColor(accentSwatch(work))));DrawTextW(draw->hDC,value.c_str(),-1,&text,DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
  RestoreDC(draw->hDC,saved);return true;
 }
 bool saveFile(const wchar_t* name,const std::string&content){if(writeAtomic(directory+L"\\"+name,content))return true;if(!saveWarned&&!locked&&!sleeping&&!quitting){saveWarned=true;error(L"Your changes couldn't be saved. Check that your device has free space and try again.");}return false;}
 void saveSettings(){captureBounds();saveFile(L"settings.ini",encodeSettings(settings));dirtySettings=false;}
 void saveTimer(){saveFile(L"timer.dat",encodeTimer(engine->save()));}
 void saveHistory(){saveFile(L"history.dat",encodeHistory(history));}
 void load(){
  directory=dataDirectory();std::string text;bool damaged=false;
  auto path=directory+L"\\settings.ini";if(exists(path)&&(!read(path,text,65536)||!decodeSettings(text,settings))){quarantine(path);settings={};damaged=true;}settings.validate();for(std::size_t i=0;i<pickerCustomColors.size();++i){auto color=settings.pickerCustomColors[i];pickerCustomColors[i]=RGB((color>>16)&0xff,(color>>8)&0xff,color&0xff);}settings.startup=startupEnabled();
  engine=std::make_unique<Engine>(settings,monotonic,utc,localTime);Saved saved;path=directory+L"\\timer.dat";
  if(settings.restore&&exists(path)){if(!read(path,text,1024)||!decodeTimer(text,saved)||!engine->restore(saved)){quarantine(path);damaged=true;}}
  path=directory+L"\\history.dat";if(exists(path)&&(!read(path,text)||!decodeHistory(text,history,utc()))){quarantine(path);history.clear();damaged=true;}
  if(damaged)PostMessageW(main,WM_APP+3,0,0);
 }
 void createFonts(){
  DWORD scale=100,size=sizeof(scale);if(RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Accessibility",L"TextScaleFactor",RRF_RT_REG_DWORD,nullptr,&scale,&size)!=ERROR_SUCCESS)scale=100;textScale=std::clamp(scale/100.0,1.0,2.25);
  if(normalFont)DeleteObject(normalFont);
  if(headingFont)DeleteObject(headingFont);
  if(tabFont)DeleteObject(tabFont);
  if(smallFont)DeleteObject(smallFont);
  if(titleFont)DeleteObject(titleFont);
  normalFont=CreateFontW(fontHeight(11),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  headingFont=CreateFontW(fontHeight(13),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  tabFont=CreateFontW(fontHeight(12),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  smallFont=CreateFontW(fontHeight(10),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  titleFont=CreateFontW(fontHeight(19),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  for(auto&c:controls)SendMessageW(c.handle,WM_SETFONT,reinterpret_cast<WPARAM>(c.kind==Kind::Heading?headingFont:normalFont),TRUE);
  for(auto h:nav)if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(tabFont),TRUE);
  for(auto h:sectionNav)if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(smallFont),TRUE);
  if(historyList)SendMessageW(historyList,WM_SETFONT,reinterpret_cast<WPARAM>(normalFont),TRUE);
 }
 void applyTheme(){
  HIGHCONTRASTW high{};high.cbSize=sizeof(high);SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(high),&high,0);colors.systemContrast=(high.dwFlags&HCF_HIGHCONTRASTON)!=0;
  DWORD light=1,size=sizeof(light);RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&light,&size);
  auto palette=theme::resolve(static_cast<theme::Mode>(settings.theme),light==0);
  colors.dark=palette.dark;colors.contrast=palette.highContrast||colors.systemContrast;
  colors.background=nativeColor(palette.background);colors.surface=nativeColor(palette.surface);colors.hover=nativeColor(palette.hover);
  colors.foreground=nativeColor(palette.foreground);colors.secondary=nativeColor(palette.secondary);colors.line=nativeColor(palette.line);
  colors.defaultWorkAccent=nativeColor(palette.workAccent);colors.defaultBreakAccent=nativeColor(palette.breakAccent);
  colors.workAccent=colors.defaultWorkAccent;colors.breakAccent=colors.defaultBreakAccent;colors.focus=nativeColor(palette.focus);
  colors.workButtonText=nativeColor(palette.workButtonText);colors.breakButtonText=nativeColor(palette.breakButtonText);
  if(!colors.contrast){
   if(settings.customWorkAccent){colors.workAccent=nativeColor(settings.workAccentColor);colors.workButtonText=nativeColor(theme::readableButtonText(settings.workAccentColor));}
   if(settings.customBreakAccent){colors.breakAccent=nativeColor(settings.breakAccentColor);colors.breakButtonText=nativeColor(theme::readableButtonText(settings.breakAccentColor));}
  }
  if(colors.systemContrast){
   colors.background=colors.surface=GetSysColor(COLOR_WINDOW);colors.hover=GetSysColor(COLOR_BTNFACE);colors.foreground=GetSysColor(COLOR_WINDOWTEXT);
   colors.secondary=GetSysColor(COLOR_GRAYTEXT);colors.line=GetSysColor(COLOR_WINDOWTEXT);colors.workAccent=GetSysColor(COLOR_HIGHLIGHT);
   colors.breakAccent=GetSysColor(COLOR_HOTLIGHT);colors.focus=GetSysColor(COLOR_HIGHLIGHT);colors.workButtonText=colors.breakButtonText=GetSysColor(COLOR_HIGHLIGHTTEXT);
   colors.dark=theme::luminance(theme::rgb(GetRValue(colors.background),GetGValue(colors.background),GetBValue(colors.background)))<0.5;
  }
  if(backgroundBrush)DeleteObject(backgroundBrush);
  backgroundBrush=CreateSolidBrush(colors.background);
  if(surfaceBrush)DeleteObject(surfaceBrush);
  surfaceBrush=CreateSolidBrush(colors.surface);
  BOOL dark=colors.dark&&!colors.systemContrast;DwmSetWindowAttribute(main,20,&dark,sizeof(dark));int rounded=2;DwmSetWindowAttribute(main,33,&rounded,sizeof(rounded));int backdrop=colors.contrast?1:2;DwmSetWindowAttribute(main,38,&backdrop,sizeof(backdrop));
  if(breakWindow){DwmSetWindowAttribute(breakWindow,20,&dark,sizeof(dark));DwmSetWindowAttribute(breakWindow,33,&rounded,sizeof(rounded));}
  for(auto&c:controls){themeControl(c.handle);if(c.buddySpin)themeControl(c.buddySpin);InvalidateRect(c.handle,nullptr,TRUE);}
  {bool darkUi=colors.dark&&!colors.systemContrast;if(settingsPane)SetWindowTheme(settingsPane,darkUi?L"DarkMode_Explorer":nullptr,nullptr);if(historyList)SetWindowTheme(historyList,darkUi?L"DarkMode_Explorer":nullptr,nullptr);}
  for(auto h:nav)if(h)InvalidateRect(h,nullptr,TRUE);
  for(auto h:sectionNav)if(h)InvalidateRect(h,nullptr,TRUE);
  if(historyList){ListView_SetBkColor(historyList,colors.background);ListView_SetTextBkColor(historyList,colors.background);ListView_SetTextColor(historyList,colors.foreground);}
  updateAccentSwatches();
  InvalidateRect(main,nullptr,TRUE);if(settingsPane)InvalidateRect(settingsPane,nullptr,TRUE);if(breakWindow)InvalidateRect(breakWindow,nullptr,TRUE);
 }
// ---- measuring and metrics ------------------------------------------------------------------------------------
 static std::wstring windowText(HWND h){wchar_t text[1024]{};GetWindowTextW(h,text,1024);return text;}
 int measureWidth(HWND h,const std::wstring&text){HDC dc=GetDC(h);auto previous=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(h,WM_GETFONT,0,0)));RECT r{0,0,0,0};DrawTextW(dc,text.c_str(),-1,&r,DT_CALCRECT|DT_SINGLELINE|DT_NOPREFIX);SelectObject(dc,previous);ReleaseDC(h,dc);return int(r.right-r.left);}
 int measureHeight(HWND h,const std::wstring&text,int width){HDC dc=GetDC(h);auto previous=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(h,WM_GETFONT,0,0)));RECT r{0,0,std::max(1,width),0};DrawTextW(dc,text.c_str(),-1,&r,DT_CALCRECT|DT_WORDBREAK|DT_NOPREFIX);SelectObject(dc,previous);ReleaseDC(h,dc);return int(r.bottom-r.top);}
 int tabHeight()const{return px(std::max(40.0,31.0*textScale));}
 int pillHeight()const{return px(std::max(28.0,21.0*textScale));}
 int fieldHeight()const{return px(std::max(32.0,21.0*textScale));}
 int navBottom()const{return px(16)+tabHeight();}
 TimerGeometry timerGeometry(int width,int buttonTop)const{
  int timerTop=navBottom()+px(22),statusBottom=timerTop+px(88);
  int diameter=std::min({px(272),width-px(100),buttonTop-statusBottom-px(18)});diameter=std::max(1,diameter);
  int left=(width-diameter)/2,top=statusBottom+px(8);
  return {left,top,diameter,left+px(4),top+px(4),diameter-px(8)};
 }
 int timerLabelWidth(const TimerGeometry&ring,int top,int height)const{return geometry::circleLabelWidth(ring.ringDiameter,px(4),top-ring.ringY,height);}
 void drawTimerRing(Gdiplus::Graphics&graphics,const TimerGeometry&ring,double progress)const{
  auto rgba=[](COLORREF color){return Gdiplus::Color(255,GetRValue(color),GetGValue(color),GetBValue(color));};
  Gdiplus::Pen track(rgba(colors.line),float(px(4))),accent(rgba(activeAccent()),float(px(4)));
  graphics.DrawEllipse(&track,ring.ringX,ring.ringY,ring.ringDiameter,ring.ringDiameter);
  progress=std::clamp(progress,0.0,1.0);
  const bool needsOutline=theme::contrastRatio(themeColor(activeAccent()),themeColor(colors.background))<3.0;
  Gdiplus::Pen outline(rgba(colors.foreground),float(px(6)));
  auto stroke=[&](Gdiplus::Pen&pen){
   if(progress>=1.0)graphics.DrawEllipse(&pen,ring.ringX,ring.ringY,ring.ringDiameter,ring.ringDiameter);
   else if(progress>0.0)graphics.DrawArc(&pen,ring.ringX,ring.ringY,ring.ringDiameter,ring.ringDiameter,float(geometry::timerProgressStartDegrees),float(geometry::timerProgressSweep(progress)));
  };
  if(needsOutline)stroke(outline);
  stroke(accent);
 }
 // One content column (the Settings shell) shared by the tab bar, the section row, the page heading, the scroll viewport and the
 // History list. The settings scroll bar lives inside this column, at its right edge.
 using Column=geometry::Column;
 Column column(int clientWidth)const{return geometry::contentColumn(clientWidth,int(dpi));}
 static COLORREF mix(COLORREF base,COLORREF tint,int tintPercent){auto channel=[&](int b,int t){return (b*(100-tintPercent)+t*tintPercent)/100;};return RGB(channel(GetRValue(base),GetRValue(tint)),channel(GetGValue(base),GetGValue(tint)),channel(GetBValue(base),GetBValue(tint)));}
 static void roundedRect(Gdiplus::GraphicsPath&path,float x,float y,float w,float h,float d){d=std::min(d,std::min(w,h));path.AddArc(x,y,d,d,180,90);path.AddArc(x+w-d,y,d,d,270,90);path.AddArc(x+w-d,y+h-d,d,d,0,90);path.AddArc(x,y+h-d,d,d,90,90);path.CloseFigure();}
 // Primary navigation is a compact tab strip (accent underline on the selected tab); section navigation is a segmented row.
 LRESULT drawTab(NMCUSTOMDRAW*draw,HWND button,int id,bool selected,bool hot,bool pressed){
  int scale=int(GetDpiForWindow(button));auto bpx=[&](int n){return std::max(1,n*scale/96);};bool tab=id<SECTION_BASE;
  RECT rect=draw->rc;FillRect(draw->hdc,&rect,backgroundBrush);auto rgba=[](COLORREF c){return Gdiplus::Color(255,GetRValue(c),GetGValue(c),GetBValue(c));};COLORREF ink;
  {Gdiplus::Graphics g(draw->hdc);g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
   if(tab){
    // Primary navigation: a tab bar that spans the content column. The selected tab is filled, set in the strongest text
    // colour and underlined with a full-width accent bar sitting on the bar's baseline.
    float x=float(rect.left),y=float(rect.top+bpx(2)),w=float(rect.right-rect.left),h=float(rect.bottom-rect.top-bpx(2)),d=float(bpx(16));
    if(selected||hot||pressed){Gdiplus::GraphicsPath path;path.AddArc(x,y,d,d,180,90);path.AddArc(x+w-d,y,d,d,270,90);path.AddLine(x+w,y+h,x,y+h);path.CloseFigure();Gdiplus::SolidBrush brush(rgba(selected?colors.surface:colors.hover));g.FillPath(&brush,&path);}
    {RECT rule{rect.left,rect.bottom-bpx(1),rect.right,rect.bottom};HBRUSH lineBrush=CreateSolidBrush(colors.line);FillRect(draw->hdc,&rule,lineBrush);DeleteObject(lineBrush);}
    if(selected){bool outline=theme::contrastRatio(themeColor(activeAccent()),themeColor(colors.background))<3.0;
     if(outline){RECT edge{rect.left,rect.bottom-bpx(5),rect.right,rect.bottom};HBRUSH focusBrush=CreateSolidBrush(colors.foreground);FillRect(draw->hdc,&edge,focusBrush);DeleteObject(focusBrush);}
     RECT bar{rect.left,rect.bottom-bpx(3),rect.right,rect.bottom};HBRUSH accentBrush=CreateSolidBrush(activeAccent());FillRect(draw->hdc,&bar,accentBrush);DeleteObject(accentBrush);}
    ink=selected||hot?colors.foreground:colors.secondary;
   }else{
    // Secondary navigation: shorter, smaller text, quiet inactive segments, a tinted (never solid) selection.
    COLORREF quiet=mix(colors.background,colors.surface,55),quietBorder=mix(colors.background,colors.line,65);
    COLORREF fill=selected?mix(colors.surface,activeAccent(),22):(hot||pressed?colors.hover:quiet);ink=selected||hot?colors.foreground:colors.secondary;
    Gdiplus::GraphicsPath path;roundedRect(path,float(rect.left+1),float(rect.top+1),float(rect.right-rect.left-2),float(rect.bottom-rect.top-2),float(bpx(10)));Gdiplus::SolidBrush brush(rgba(fill));Gdiplus::Pen border(rgba(selected?activeAccent():quietBorder),float(bpx(colors.contrast?2:1)));g.FillPath(&brush,&path);g.DrawPath(&border,&path);
   }
  }
  wchar_t caption[64]{};GetWindowTextW(button,caption,64);int saved=SaveDC(draw->hdc);
  SelectObject(draw->hdc,reinterpret_cast<HFONT>(SendMessageW(button,WM_GETFONT,0,0)));
  UINT flags=DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS;LRESULT cues=SendMessageW(button,WM_QUERYUISTATE,0,0);if(cues&UISF_HIDEACCEL)flags|=DT_HIDEPREFIX;
  RECT text=rect;InflateRect(&text,-bpx(tab?8:5),0);if(tab)text.bottom-=bpx(3);
  SetTextColor(draw->hdc,ink);SetBkMode(draw->hdc,TRANSPARENT);DrawTextW(draw->hdc,caption,-1,&text,flags);
  if((draw->uItemState&CDIS_FOCUS)&&!(cues&UISF_HIDEFOCUS)){RECT focus=rect;InflateRect(&focus,-bpx(4),-bpx(4));if(colors.contrast){HPEN pen=CreatePen(PS_SOLID,bpx(2),colors.focus);HGDIOBJ oldPen=SelectObject(draw->hdc,pen),oldBrush=SelectObject(draw->hdc,GetStockObject(NULL_BRUSH));Rectangle(draw->hdc,focus.left,focus.top,focus.right,focus.bottom);SelectObject(draw->hdc,oldBrush);SelectObject(draw->hdc,oldPen);DeleteObject(pen);}else DrawFocusRect(draw->hdc,&focus);}
  RestoreDC(draw->hdc,saved);return CDRF_SKIPDEFAULT;
 }
 // The volume slider is custom drawn so it matches the rest of the page: a thin track with an accent fill and a round thumb.
 LRESULT drawTrackbar(NMCUSTOMDRAW*draw){
  if(draw->dwDrawStage==CDDS_PREPAINT)return CDRF_NOTIFYITEMDRAW;
  if(draw->dwDrawStage!=CDDS_ITEMPREPAINT)return CDRF_DODEFAULT;
  HWND bar=draw->hdr.hwndFrom;int scale=int(GetDpiForWindow(bar));auto bpx=[&](int n){return std::max(1,n*scale/96);};
  RECT thumb{};SendMessageW(bar,TBM_GETTHUMBRECT,0,reinterpret_cast<LPARAM>(&thumb));int thumbX=(thumb.left+thumb.right)/2;
  auto rgba=[](COLORREF c){return Gdiplus::Color(255,GetRValue(c),GetGValue(c),GetBValue(c));};
  Gdiplus::Graphics g(draw->hdc);g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  if(draw->dwItemSpec==TBCD_CHANNEL){RECT channel=draw->rc,whole{};GetClientRect(bar,&whole);float t=float(bpx(4)),y=float((channel.top+channel.bottom)/2)-t/2,x0=float(whole.left),x1=float(whole.right);
   Gdiplus::GraphicsPath track;roundedRect(track,x0,y,x1-x0,t,t);Gdiplus::SolidBrush line(rgba(colors.line));g.FillPath(&line,&track);
   if(thumbX>x0){Gdiplus::GraphicsPath filled;roundedRect(filled,x0,y,float(thumbX)-x0,t,t);Gdiplus::SolidBrush accent(rgba(activeAccent()));g.FillPath(&accent,&filled);}
   return CDRF_SKIPDEFAULT;}
  if(draw->dwItemSpec==TBCD_THUMB){float d=float(bpx(16)),cx=float((thumb.left+thumb.right)/2),cy=float((thumb.top+thumb.bottom)/2);
   Gdiplus::SolidBrush ring(rgba(colors.background));g.FillEllipse(&ring,cx-d/2-float(bpx(2)),cy-d/2-float(bpx(2)),d+float(bpx(4)),d+float(bpx(4)));
   Gdiplus::SolidBrush accent(rgba(activeAccent()));g.FillEllipse(&accent,cx-d/2,cy-d/2,d,d);return CDRF_SKIPDEFAULT;}
  return CDRF_SKIPDEFAULT;
 }
 void themeControl(HWND h){
  wchar_t name[32]{};GetClassNameW(h,name,32);bool dark=colors.dark&&!colors.systemContrast;
  if(wcscmp(name,L"Button")==0)SetWindowTheme(h,nullptr,nullptr);
  else if(wcscmp(name,L"ComboBox")==0)SetWindowTheme(h,dark?L"DarkMode_CFD":nullptr,nullptr);
  else if(wcscmp(name,UPDOWN_CLASSW)==0)SetWindowTheme(h,dark?L"DarkMode_Explorer":nullptr,nullptr);
 }
 // Number fields draw their own 1 px frame and centre the text vertically; the native client edge is light and top-aligned.
 static LRESULT CALLBACK editProc(HWND h,UINT msg,WPARAM w,LPARAM l,UINT_PTR,DWORD_PTR){
  auto&a=*app;
  switch(msg){
   case WM_NCCALCSIZE:if(w){auto*params=reinterpret_cast<NCCALCSIZE_PARAMS*>(l);RECT&r=params->rgrc[0];int border=std::max(1,a.px(1));
     HDC dc=GetDC(h);auto previous=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(h,WM_GETFONT,0,0)));TEXTMETRICW tm{};GetTextMetricsW(dc,&tm);SelectObject(dc,previous);ReleaseDC(h,dc);
     int vertical=std::max(border,int((r.bottom-r.top-tm.tmHeight)/2));r.left+=border;r.right-=border;r.top+=vertical;r.bottom-=vertical;return 0;}break;
   case WM_NCPAINT:{HDC dc=GetWindowDC(h);RECT window{};GetWindowRect(h,&window);int border=std::max(1,a.px(1));bool focused=GetFocus()==h;
     // A window DC also covers the client area. Scrolling moves fields with copied bits and repaints only their frame, so
     // painting over the client here erased the text with nothing to redraw it; the frame is painted around the client.
     RECT client{};GetClientRect(h,&client);MapWindowPoints(h,nullptr,reinterpret_cast<POINT*>(&client),2);OffsetRect(&client,-window.left,-window.top);
     OffsetRect(&window,-window.left,-window.top);ExcludeClipRect(dc,client.left,client.top,client.right,client.bottom);
     FillRect(dc,&window,a.surfaceBrush);HPEN pen=CreatePen(PS_SOLID,focused?a.px(2):border,focused?a.colors.focus:a.colors.line);auto oldPen=SelectObject(dc,pen);auto oldBrush=SelectObject(dc,GetStockObject(NULL_BRUSH));
     Rectangle(dc,window.left,window.top,window.right,window.bottom);SelectObject(dc,oldBrush);SelectObject(dc,oldPen);DeleteObject(pen);ReleaseDC(h,dc);return 0;}
   case WM_SETFOCUS:case WM_KILLFOCUS:{LRESULT result=DefSubclassProc(h,msg,w,l);RedrawWindow(h,nullptr,nullptr,RDW_FRAME|RDW_INVALIDATE);return result;}
   case WM_NCDESTROY:RemoveWindowSubclass(h,editProc,1);break;
  }
  return DefSubclassProc(h,msg,w,l);
 }
 // ---- settings content ----------------------------------------------------------------------------------------------
 HWND control(const wchar_t*cls,const wchar_t*text,DWORD style,int id,int onPage,Kind kind=Kind::Plain,HWND parent=nullptr){
  // The settings pane controls inherit page visibility from their parent.
  HWND h=CreateWindowExW(0,cls,text,WS_CHILD|WS_VISIBLE|(wcscmp(cls,L"STATIC")==0?0:WS_TABSTOP)|style,0,0,1,1,parent?parent:main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);
  if(!h)throw std::runtime_error("Could not create native control");
  if(wcscmp(cls,L"EDIT")==0)SetWindowSubclass(h,editProc,1,0);
  SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(normalFont),TRUE);Control c;c.handle=h;c.id=id;c.page=onPage;c.kind=kind;c.section=buildSection;controls.push_back(c);themeControl(h);return h;
 }
 HWND label(const wchar_t*text,Kind kind=Kind::Plain,bool indent=false){
  DWORD style=(kind==Kind::Value?SS_RIGHT:SS_LEFT)|SS_NOPREFIX|(kind==Kind::Caption||kind==Kind::Value||kind==Kind::Inline?SS_CENTERIMAGE:0); // the value readout is right-aligned so it ends on the column edge
  HWND h=control(L"STATIC",text,style,-1,2,kind,settingsPane);controls.back().indent=indent;if(kind==Kind::Hint)SetWindowLongPtrW(h,GWLP_USERDATA,1);
  SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(kind==Kind::Heading?headingFont:normalFont),TRUE);return h;
 }
 void hint(const wchar_t*text,bool indent=false){label(text,Kind::Hint,indent);}
 void checkbox(const wchar_t*text,int id,int onPage,bool checked,HWND parent){HWND h=control(L"BUTTON",text,BS_AUTOCHECKBOX|BS_MULTILINE,id,onPage,Kind::Check,parent);SendMessageW(h,BM_SETCHECK,checked?BST_CHECKED:BST_UNCHECKED,0);}
 void combo(const wchar_t*labelText,int id,const std::vector<std::wstring>&items,int selected){
  label(labelText,Kind::Caption);HWND h=control(WC_COMBOBOXW,L"",CBS_DROPDOWNLIST|WS_VSCROLL,id,2,Kind::Field,settingsPane);for(auto&s:items)SendMessageW(h,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(s.c_str()));
  SendMessageW(h,CB_SETMINVISIBLE,8,0);SendMessageW(h,CB_SETITEMHEIGHT,WPARAM(-1),LPARAM(fieldHeight()-px(6)));SendMessageW(h,CB_SETCURSEL,selected,0);
 }
 void number(const wchar_t*labelText,int id,int value,int low,int high){label(labelText,Kind::Caption);HWND h=control(L"EDIT",std::to_wstring(value).c_str(),ES_NUMBER|ES_AUTOHSCROLL,id,2,Kind::Field,settingsPane);SendMessageW(h,EM_SETLIMITTEXT,3,0);SendMessageW(h,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(px(10),px(10)));
  HWND spin=CreateWindowExW(0,UPDOWN_CLASSW,L"",WS_CHILD|WS_VISIBLE|UDS_ALIGNRIGHT|UDS_SETBUDDYINT|UDS_ARROWKEYS,0,0,0,0,settingsPane,nullptr,instance,nullptr);if(!spin)throw std::runtime_error("Could not create number control");controls.back().buddySpin=spin;themeControl(spin);SendMessageW(spin,UDM_SETBUDDY,reinterpret_cast<WPARAM>(h),0);SendMessageW(spin,UDM_SETRANGE32,low,high);SendMessageW(spin,UDM_SETPOS32,0,value);}
 void accessibleName(HWND h,const std::wstring&name){
  if(!accessibility&&FAILED(CoCreateInstance(CLSID_AccPropServices,nullptr,CLSCTX_INPROC_SERVER,IID_IAccPropServices,reinterpret_cast<void**>(&accessibility))))accessibility=nullptr;
  if(accessibility&&SUCCEEDED(accessibility->SetHwndPropStr(h,DWORD(OBJID_CLIENT),DWORD(CHILDID_SELF),PROPID_ACC_NAME,name.c_str())))annotated.push_back(h);
 }
 void clearAccessibleNames(){if(accessibility)for(HWND h:annotated){MSAAPROPID name=PROPID_ACC_NAME;accessibility->ClearHwndProps(h,DWORD(OBJID_CLIENT),DWORD(CHILDID_SELF),&name,1);}annotated.clear();}
 // Inline row parts for the weekly hours. A row starts with an indented label; the label is kept on the same line as its field.
 void rowLabel(const wchar_t*text,int day,bool first){label(text,Kind::Inline);auto&c=controls.back();c.sameRow=!first;c.indent=first;c.keep=true;c.group=day;}
 void timeField(int id,int minutes,int day,const std::wstring&name){
  HWND h=control(L"EDIT",wide(formatClock(minutes)).c_str(),ES_CENTER|ES_AUTOHSCROLL,id,2,Kind::Inline,settingsPane);auto&c=controls.back();c.sameRow=true;c.group=day;
  SendMessageW(h,EM_SETLIMITTEXT,5,0);SendMessageW(h,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(px(6),px(6)));accessibleName(h,name+L", 24-hour");
 }
 void rowButton(const wchar_t*text,int id,int day,const std::wstring&name){HWND h=control(L"BUTTON",text,BS_PUSHBUTTON,id,2,Kind::Inline,settingsPane);auto&c=controls.back();c.sameRow=true;c.group=day;accessibleName(h,name);}
 void accentRow(const wchar_t*caption,int swatchId,int buttonId,const wchar_t*accessible){
  label(caption,Kind::Inline);controls.back().keep=true;
  control(L"STATIC",L"#000000",SS_OWNERDRAW|SS_NOPREFIX|SS_CENTERIMAGE,swatchId,2,Kind::Inline,settingsPane);controls.back().sameRow=true;
  HWND choose=control(L"BUTTON",L"Choose Colour...",BS_PUSHBUTTON,buttonId,2,Kind::Inline,settingsPane);controls.back().sameRow=true;accessibleName(choose,accessible);
 }
 // One day of the weekly hours: its check box, then one row per period ("From [start] to [end] [Remove]") with Add on the last row.
 void scheduleDay(int d){
  const auto&s=settings.schedule;checkbox(DAY_NAMES[d],DAY_BASE+d,2,s.days[d],settingsPane);
  for(int i=0;i<s.counts[d];++i){
   const Period&p=s.periods[d][i];int base=PERIOD_BASE+d*10+i*3;std::wstring which=std::wstring(DAY_NAMES[d])+L", period "+std::to_wstring(i+1);
   rowLabel(L"From",d,true);timeField(base,p.start,d,which+L", start time");rowLabel(L"to",d,false);timeField(base+1,p.end,d,which+L", end time");
   if(s.counts[d]>1)rowButton(L"Remove",base+2,d,L"Remove "+which);
   if(i==s.counts[d]-1&&s.counts[d]<Schedule::maxPeriods)rowButton(L"Add period",PERIOD_BASE+d*10+9,d,std::wstring(L"Add a period to ")+DAY_NAMES[d]);
  }
  enableDay(d);
 }
 // An unselected day keeps its hours but greys them out; its labels use the secondary text colour.
 void enableDay(int d){bool on=settings.schedule.days[d];for(auto&c:controls)if(c.group==d){if(c.kind==Kind::Inline&&c.id<0)SetWindowLongPtrW(c.handle,GWLP_USERDATA,on?0:1);else EnableWindow(c.handle,on?TRUE:FALSE);InvalidateRect(c.handle,nullptr,TRUE);}}
 HWND find(int id){for(auto&c:controls)if(c.id==id)return c.handle;return nullptr;}
 void updateVolumeLabel(){HWND v=find(VOLUME_VALUE);if(v)SetWindowTextW(v,(std::to_wstring(settings.volume)+L"%").c_str());}
 std::wstring installedVersion()const{
  const auto path=executable();DWORD ignored=0,size=GetFileVersionInfoSizeW(path.c_str(),&ignored);if(!size)return{};
  std::vector<unsigned char> data(size);if(!GetFileVersionInfoW(path.c_str(),0,size,data.data()))return{};
  VS_FIXEDFILEINFO* info=nullptr;UINT length=0;if(!VerQueryValueW(data.data(),L"\\",reinterpret_cast<void**>(&info),&length)||!info||length<sizeof(*info))return{};
  return std::to_wstring(HIWORD(info->dwProductVersionMS))+L"."+std::to_wstring(LOWORD(info->dwProductVersionMS))+L"."+std::to_wstring(HIWORD(info->dwProductVersionLS));
 }
 static updates::Failure networkFailure(DWORD code){
  if(code==ERROR_WINHTTP_TIMEOUT)return updates::Failure::Timeout;
  if(code==ERROR_WINHTTP_SECURE_FAILURE)return updates::Failure::SecureConnection;
  if(code==ERROR_WINHTTP_NAME_NOT_RESOLVED||code==ERROR_WINHTTP_CANNOT_CONNECT||code==ERROR_WINHTTP_CONNECTION_ERROR)return updates::Failure::Offline;
  return updates::Failure::Other;
 }
 static updates::HttpResponse latestReleaseResponse(){
#ifdef EYEBREAK_TEST_BUILD
  std::wstring fixturePath=executable();const auto slash=fixturePath.find_last_of(L"\\/");if(slash!=std::wstring::npos)fixturePath.resize(slash+1);fixturePath+=L"test-update-response.txt";
  std::string fixture;
  if(read(fixturePath,fixture,65536)){
   updates::HttpResponse response;response.status=200;auto separator=fixture.find("\r\n\r\n");std::size_t bodyStart=separator==std::string::npos?std::string::npos:separator+4;
   if(separator==std::string::npos){separator=fixture.find("\n\n");if(separator!=std::string::npos)bodyStart=separator+2;}
   if(separator==std::string::npos){response.body=std::move(fixture);return response;}
   std::istringstream headers(fixture.substr(0,separator));std::string line;
   while(std::getline(headers,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();const auto equals=line.find('=');if(equals==std::string::npos)continue;const auto key=line.substr(0,equals),value=line.substr(equals+1);
    if(key=="status")response.status=std::clamp(std::atoi(value.c_str()),0,999);
    else if(key=="failure"){if(value=="offline")response.failure=updates::Failure::Offline;else if(value=="timeout")response.failure=updates::Failure::Timeout;else if(value=="tls")response.failure=updates::Failure::SecureConnection;else if(value=="other")response.failure=updates::Failure::Other;}
    else if(key=="error")response.errorCode=std::strtoul(value.c_str(),nullptr,10);
    else if(key=="delay_ms")Sleep(std::min<DWORD>(30000,DWORD(std::strtoul(value.c_str(),nullptr,10))));
   }
   response.body=fixture.substr(bodyStart);return response;
  }
#endif
  struct Handle {HINTERNET value{};~Handle(){if(value)WinHttpCloseHandle(value);}};
  updates::HttpResponse response;
  Handle session{WinHttpOpen(L"Eye Break Reminder (Windows x64)",WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0)};
  if(!session.value){response.failure=networkFailure(GetLastError());response.errorCode=GetLastError();return response;}
  WinHttpSetTimeouts(session.value,5000,5000,5000,10000);
  Handle connection{WinHttpConnect(session.value,L"api.github.com",INTERNET_DEFAULT_HTTPS_PORT,0)};
  if(!connection.value){response.failure=networkFailure(GetLastError());response.errorCode=GetLastError();return response;}
  Handle request{WinHttpOpenRequest(connection.value,L"GET",L"/repos/REMEDIOSSAMUEL/EYE-BREAK-REMINDER/releases/latest",nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE)};
  if(!request.value){response.failure=networkFailure(GetLastError());response.errorCode=GetLastError();return response;}
  const wchar_t* headers=L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n";
  if(!WinHttpAddRequestHeaders(request.value,headers,DWORD(-1),WINHTTP_ADDREQ_FLAG_ADD|WINHTTP_ADDREQ_FLAG_REPLACE)||
     !WinHttpSendRequest(request.value,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0)||
     !WinHttpReceiveResponse(request.value,nullptr)){
   const DWORD error=GetLastError();response.failure=networkFailure(error);response.errorCode=error;return response;
  }
  DWORD status=0,statusSize=sizeof(status);
  if(!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&statusSize,WINHTTP_NO_HEADER_INDEX)){
   const DWORD error=GetLastError();response.failure=networkFailure(error);response.errorCode=error;return response;
  }
  response.status=int(status);
  for(;;){DWORD available=0;if(!WinHttpQueryDataAvailable(request.value,&available)){const DWORD error=GetLastError();response.failure=networkFailure(error);response.errorCode=error;return response;}if(!available)break;
   const DWORD amount=std::min<DWORD>(available,DWORD(65537-response.body.size()));if(!amount)break;const auto old=response.body.size();response.body.resize(old+amount);DWORD read=0;
   if(!WinHttpReadData(request.value,response.body.data()+old,amount,&read)){const DWORD error=GetLastError();response.failure=networkFailure(error);response.errorCode=error;response.body.clear();return response;}
   response.body.resize(old+read);if(!read||response.body.size()>65536)break;
  }
  return response;
 }
 void setUpdateLabel(int id,const std::wstring&value){if(HWND h=find(id))SetWindowTextW(h,value.c_str());if(page==2&&settingsSection==5)layoutSettings();}
 void applyUpdateResult(const updates::CheckResult& result){
  updateCheckActive=false;updateReleaseUrl.clear();EnableWindow(find(UPDATE_CHECK),TRUE);SetWindowTextW(find(UPDATE_CHECK),L"Check for Updates");
  if(result.state==updates::State::Failed){setUpdateLabel(UPDATE_LATEST,L"Latest stable version: unavailable");setUpdateLabel(UPDATE_STATUS,wide(result.error));EnableWindow(find(UPDATE_OPEN),FALSE);}
  else{
   setUpdateLabel(UPDATE_LATEST,L"Latest stable version: "+wide(result.latestVersion));
   if(result.state==updates::State::UpdateAvailable){updateReleaseUrl=wide(result.releaseUrl);setUpdateLabel(UPDATE_STATUS,L"An update is available. Open the official release page to review its downloads.");EnableWindow(find(UPDATE_OPEN),TRUE);}
   else if(result.state==updates::State::InstalledNewer){setUpdateLabel(UPDATE_STATUS,L"The installed version is newer than the latest stable release.");EnableWindow(find(UPDATE_OPEN),FALSE);}
   else {setUpdateLabel(UPDATE_STATUS,L"Eye Break Reminder is up to date.");EnableWindow(find(UPDATE_OPEN),FALSE);}
  }
  if(HWND h=find(UPDATE_CHECK))InvalidateRect(h,nullptr,TRUE);
  if(HWND h=find(UPDATE_OPEN))InvalidateRect(h,nullptr,TRUE);
 }
 void startUpdateCheck(){
  bool expected=false;if(!updateCheckActive.compare_exchange_strong(expected,true))return;
  HWND button=find(UPDATE_CHECK);if(button){EnableWindow(button,FALSE);SetWindowTextW(button,L"Checking…");InvalidateRect(button,nullptr,TRUE);}
  setUpdateLabel(UPDATE_STATUS,L"Checking the official stable release on GitHub…");setUpdateLabel(UPDATE_LATEST,L"Latest stable version: checking…");EnableWindow(find(UPDATE_OPEN),FALSE);updateReleaseUrl.clear();
  const std::wstring installed=installedVersion();auto dispatch=updateDispatch;
  try{std::thread([dispatch,installed]{
    updates::CheckResult result;
    try{result=updates::evaluate(latestReleaseResponse(),utf8(installed));}
    catch(...){result.error="The update check could not be completed.";}
    std::unique_ptr<UpdateMessage> message(new(std::nothrow) UpdateMessage{std::move(result)});if(!message)return;
    std::lock_guard<std::mutex> lock(dispatch->mutex);
    if(dispatch->alive&&dispatch->target&&PostMessageW(dispatch->target,UPDATE_RESULT,0,reinterpret_cast<LPARAM>(message.get())))message.release();
   }).detach();}
  catch(...){updateCheckActive=false;EnableWindow(find(UPDATE_CHECK),TRUE);SetWindowTextW(find(UPDATE_CHECK),L"Check for Updates");setUpdateLabel(UPDATE_STATUS,L"Windows could not start the update check.");}
 }
 void openOfficialRelease(){if(updateReleaseUrl.empty())return;auto result=reinterpret_cast<INT_PTR>(ShellExecuteW(main,L"open",updateReleaseUrl.c_str(),nullptr,nullptr,SW_SHOWNORMAL));if(result<=32)error(L"The official release page couldn't be opened. Check your default browser settings.");}
 // Stop is only useful while something is playing. The audio object only posts a request (never touches the UI itself), so
 // alarm playback never runs UI code; the request is coalesced and evaluated once the audio call has returned.
 void postPreviewRefresh(){if(previewRefreshPosted||!main)return;previewRefreshPosted=true;PostMessageW(main,PREVIEW_REFRESH,0,0);}
 void refreshPreview(){
  HWND stop=find(STOP_AUDIO);if(!stop||!IsWindow(stop))return;
  bool playing=audio&&audio->playing;if((IsWindowEnabled(stop)!=FALSE)==playing)return;
  if(!playing&&GetFocus()==stop){HWND preview=find(PREVIEW);if(preview)SetFocus(preview);}
  EnableWindow(stop,playing?TRUE:FALSE);InvalidateRect(stop,nullptr,TRUE);
 }
#pragma GCC diagnostic push
// GCC 15 reports a false "free-nonheap-object" for the temporary string vectors passed to combo() below.
#pragma GCC diagnostic ignored "-Wfree-nonheap-object"
 void buildSettings(){
  loading=true;buildSection=0;clearAccessibleNames();for(auto it=controls.begin();it!=controls.end();){if(it->page==2){DestroyWindow(it->handle);it=controls.erase(it);}else ++it;}
  // Buddy spin controls are recreated with their edits.
  EnumChildWindows(settingsPane,[](HWND child,LPARAM)->BOOL{wchar_t name[64]{};GetClassNameW(child,name,64);if(wcscmp(name,UPDOWN_CLASSW)==0)DestroyWindow(child);return TRUE;},0);
  label(L"Work and break intervals",Kind::Heading);number(L"Work interval (minutes)",WORK,settings.workMinutes,1,180);number(L"Break duration (seconds)",BREAK_SECONDS,settings.breakSeconds,5,300);
  hint(L"Changes apply to the next cycle. Reset starts a fresh work interval.");
  buildSection=SCHEDULE_SECTION;label(L"Operating schedule",Kind::Heading);checkbox(L"Enable operating schedule",SCHEDULE_TOGGLE,2,settings.schedule.enabled,settingsPane);
  hint(L"Automatic eye-break reminders only run during the selected days and hours. Outside them the countdown waits; Pause, Reset and Take a break now still work.");
  label(L"Quick setup",Kind::Heading);control(L"BUTTON",L"Weekdays 09:00–17:00",BS_PUSHBUTTON,PRESET_WEEKDAYS,2,Kind::Button,settingsPane);control(L"BUTTON",L"Every day 09:00–17:00",BS_PUSHBUTTON,PRESET_EVERYDAY,2,Kind::Button,settingsPane);controls.back().sameRow=true;
  hint(L"For a custom schedule, choose the days and hours below.");
  label(L"Weekly hours",Kind::Heading);
  hint(L"24-hour local time, up to three periods a day. A period that ends earlier than it starts continues past midnight, even into a day that is off. Use 00:00 to 24:00 for a whole day. Overlapping or touching periods count as one.");
  for(int d=0;d<7;++d)scheduleDay(d);
  label(L"Status",Kind::Heading);label(scheduleStatus().c_str());controls.back().id=SCHEDULE_STATUS;
  hint(L"Eye Break Reminder must be running, in a window or in the tray, for the schedule to apply. It does not start the app; use Start with Windows for that.");
  buildSection=2;label(L"Alarm",Kind::Heading);checkbox(L"Alarm enabled",ALARM_TOGGLE,2,settings.alarm,settingsPane);
  combo(L"Alarm sound",SOUND,{L"Gentle",L"Bell",L"Chime",L"Clear",L"Soft"},settings.sound);
  label(L"Alarm volume",Kind::Caption);HWND volume=control(TRACKBAR_CLASSW,L"",TBS_NOTICKS|TBS_BOTH,VOLUME,2,Kind::Slider,settingsPane);SendMessageW(volume,TBM_SETRANGE,TRUE,MAKELONG(0,100));SendMessageW(volume,TBM_SETPOS,TRUE,settings.volume);SetWindowTextW(volume,L"Alarm volume, percent");
  label((std::to_wstring(settings.volume)+L"%").c_str(),Kind::Value);controls.back().id=VOLUME_VALUE;controls.back().sameRow=true;
  checkbox(L"Repeat until the break ends or is acknowledged",REPEAT,2,settings.repeat,settingsPane);
  control(L"BUTTON",L"Preview alarm",BS_PUSHBUTTON,PREVIEW,2,Kind::Button,settingsPane);control(L"BUTTON",L"Stop preview",BS_PUSHBUTTON,STOP_AUDIO,2,Kind::Button,settingsPane);controls.back().sameRow=true;
  buildSection=3;label(L"Break reminders",Kind::Heading);checkbox(L"Windows notifications",NOTIFY,2,settings.notifications,settingsPane);checkbox(L"Allow snooze (1, 3 or 5 minutes)",SNOOZE,2,settings.snooze,settingsPane);
  label(L"Break window",Kind::Heading);
  combo(L"Break presentation",MODE,{L"Normal window",L"Compact reminder",L"Fullscreen reminder (opt in)"},settings.mode);combo(L"Preferred monitor",MONITOR,{L"Active display",L"Primary display",L"Selected display"},settings.monitor);
  displays=monitors();std::vector<std::wstring> names;int chosen=0;for(std::size_t i=0;i<displays.size();++i){names.push_back(L"Display "+std::to_wstring(i+1)+(displays[i].primary?L" (primary)":L""));if(utf8(displays[i].device)==settings.selectedMonitor)chosen=int(i);}combo(L"Selected display",SELECT_MONITOR,names,chosen);
  buildSection=4;label(L"Appearance",Kind::Heading);combo(L"Theme",THEME,{L"Follow Windows Theme",L"Light",L"Dark",L"High Contrast Dark",L"High Contrast Light"},settings.theme);
  checkbox(L"Use a distinct accent during eye breaks",BREAK_COLORS,2,settings.breakModeColors,settingsPane);
  label(L"CUSTOM ACCENT COLOURS",Kind::Heading);
  accentRow(L"Work Mode colour",WORK_ACCENT_SWATCH,CHOOSE_WORK_ACCENT,L"Choose Work Mode colour");
  accentRow(L"Break Mode colour",BREAK_ACCENT_SWATCH,CHOOSE_BREAK_ACCENT,L"Choose Break Mode colour");
  control(L"BUTTON",L"Reset to Default Colours",BS_PUSHBUTTON,RESET_ACCENT_COLORS,2,Kind::Button,settingsPane);
  hint(L"High contrast themes and Windows Forced Colors always use their accessible system colours.",true);
  label(L"Behaviour",Kind::Heading);checkbox(L"Start timer automatically on launch",AUTO_START,2,settings.autoStart,settingsPane);checkbox(L"Start with Windows",STARTUP,2,settings.startup,settingsPane);
  hint(L"Open Eye Break Reminder automatically when you sign in.",true);checkbox(L"Minimize to system tray",TRAY,2,settings.tray,settingsPane);hint(L"Closing keeps reminders active. Choose Exit in the tray menu to quit.",true);
  checkbox(L"Resume countdown when reopening the app",RESTORE,2,settings.restore,settingsPane);hint(L"Reinstalling after uninstall starts a fresh work interval. Preferences and history are kept.",true);checkbox(L"Pause while workstation is locked",PAUSE_LOCK,2,settings.pauseLocked,settingsPane);
  hint(L"Sleep counts as elapsed work time. Wake shows at most one reminder. Paused timers stay paused.",true);
  buildSection=5;label(L"About",Kind::Heading);label(L"Eye Break Reminder");hint((L"Installed version: "+installedVersion()).c_str());controls.back().id=UPDATE_INSTALLED;
  hint(L"Latest stable version: not checked");controls.back().id=UPDATE_LATEST;
  hint(L"Select Check for Updates to query the official public GitHub Releases API.");controls.back().id=UPDATE_STATUS;
  control(L"BUTTON",L"Check for Updates",BS_PUSHBUTTON,UPDATE_CHECK,2,Kind::Button,settingsPane);
  control(L"BUTTON",L"Open Official Release",BS_PUSHBUTTON,UPDATE_OPEN,2,Kind::Button,settingsPane);EnableWindow(find(UPDATE_OPEN),FALSE);
  hint(L"The checker only reports release information. It never downloads or runs an installer.",true);
  hint(L"All data stays on this device. No internet, telemetry, account, camera or microphone.");
  label(L"Accessibility",Kind::Heading);hint(L"Uses Windows text scaling, high contrast and keyboard focus.");
  hint(L"Ctrl+R: Reset · Ctrl+Shift+B: Take break · Ctrl+comma: Settings");
  control(L"BUTTON",L"Reset all settings",BS_PUSHBUTTON,RESET_SETTINGS,2,Kind::Button,settingsPane);loading=false;refreshPreview();layout();
 }
#pragma GCC diagnostic pop
 void createControls(){
  dpi=GetDpiForWindow(main);createFonts();
  for(int i=0;i<3;++i){nav[i]=CreateWindowExW(0,L"BUTTON",i==0?L"&Timer":i==1?L"&History":L"&Settings",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTORADIOBUTTON|BS_PUSHLIKE|(i==0?WS_GROUP:0),0,0,0,0,main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(NAV_TIMER+i)),instance,nullptr);SendMessageW(nav[i],WM_SETFONT,reinterpret_cast<WPARAM>(tabFont),TRUE);}
  control(L"STATIC",L"Running",SS_CENTER|SS_CENTERIMAGE|SS_ENDELLIPSIS,TIMER_STATE,0);control(L"STATIC",L"Next eye break",SS_CENTER|SS_CENTERIMAGE|SS_ENDELLIPSIS,COUNT_CAPTION,0);control(L"STATIC",L"20:00",SS_CENTER|SS_CENTERIMAGE|SS_ENDELLIPSIS,COUNTDOWN,0);
  control(L"BUTTON",L"Take a break now",BS_DEFPUSHBUTTON,TAKE_BREAK,0);control(L"BUTTON",L"Pause",BS_PUSHBUTTON,PAUSE,0);control(L"BUTTON",L"Reset",BS_PUSHBUTTON,RESET,0);
  historyList=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"Eye break history",WS_CHILD|WS_TABSTOP|LVS_REPORT|LVS_SINGLESEL|LVS_SHOWSELALWAYS,0,0,1,1,main,reinterpret_cast<HMENU>(200),instance,nullptr);ListView_SetExtendedListViewStyle(historyList,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER);
  for(int i=0;i<3;++i){LVCOLUMNW col{};col.mask=LVCF_TEXT|LVCF_WIDTH|LVCF_SUBITEM;col.pszText=const_cast<LPWSTR>(i==0?L"Date":i==1?L"Break":L"Seconds");col.cx=px(i==0?240:140);col.iSubItem=i;ListView_InsertColumn(historyList,i,&col);}
  checkbox(L"Save history on this device",HISTORY_TOGGLE,1,settings.history,main);control(L"BUTTON",L"Clear history",BS_PUSHBUTTON,CLEAR_HISTORY,1);
  {const wchar_t*names[SECTION_COUNT]={L"Intervals",L"Schedule",L"Alarm",L"Reminders",L"General",L"About"};
   for(int i=0;i<SECTION_COUNT;++i){sectionNav[i]=CreateWindowExW(0,L"BUTTON",names[i],WS_CHILD|WS_TABSTOP|BS_AUTORADIOBUTTON|BS_PUSHLIKE|(i==0?WS_GROUP:0),0,0,0,0,main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(SECTION_BASE+i)),instance,nullptr);SendMessageW(sectionNav[i],WM_SETFONT,reinterpret_cast<WPARAM>(smallFont),TRUE);}}
  settingsPane=CreateWindowExW(WS_EX_CONTROLPARENT,L"EyeBreakReminder.Settings",L"Settings",WS_CHILD|WS_VSCROLL|WS_CLIPCHILDREN|WS_GROUP,0,0,1,1,main,nullptr,instance,nullptr);buildSettings();selectSection(0);switchPage(0);
 }
 // Settings show one section at a time; each section's controls are laid out and scrolled on their own.
 void selectSection(int index){
  settingsSection=std::clamp(index,0,SECTION_COUNT-1);
  for(int i=0;i<SECTION_COUNT;++i){SendMessageW(sectionNav[i],BM_SETCHECK,i==settingsSection?BST_CHECKED:BST_UNCHECKED,0);InvalidateRect(sectionNav[i],nullptr,TRUE);}
  settingsScroller.jump(0);layoutSettings();
 }
 void switchPage(int next){page=next;settleScroll();for(auto h:sectionNav)ShowWindow(h,page==2?SW_SHOW:SW_HIDE);for(int i=0;i<3;++i){SendMessageW(nav[i],BM_SETCHECK,i==page?BST_CHECKED:BST_UNCHECKED,0);InvalidateRect(nav[i],nullptr,TRUE);}
  for(auto&c:controls)if(c.page!=2)ShowWindow(c.handle,c.page==page?SW_SHOW:SW_HIDE);
  if(page==0)updateAccessibleTimer();
  ShowWindow(settingsPane,page==2?SW_SHOW:SW_HIDE);ShowWindow(historyList,page==1?SW_SHOW:SW_HIDE);if(page==1)updateHistory();layout();updateRenderTimer();InvalidateRect(main,nullptr,TRUE);}
 void layout(){
  if(!main||!settingsPane)return;
  std::vector<Placement> moves;auto move=[&](HWND window,int x,int y,int w,int h){if(window)moves.push_back({window,x,y,w,h});};
  RECT client{};GetClientRect(main,&client);int w=client.right,h=client.bottom,pad=px(28),gap=px(12),bh=px(std::max(36.0,30.0*textScale));
  Column col=column(w);int tabTop=px(16),tabHeightNow=tabHeight();
  {std::vector<int> natural;for(int i=0;i<3;++i){std::wstring text=windowText(nav[i]);text.erase(std::remove(text.begin(),text.end(),L'&'),text.end());natural.push_back(measureWidth(nav[i],text)+px(40));}
   for(auto&segment:geometry::segmentRows(natural,col.x,col.width,0,px(60),false))move(nav[segment.index],segment.x,tabTop,segment.width,tabHeightNow);}
  int top=navBottom()+px(28);
  if(page==0){int footer=timerFooterTextHeight(col.width),bottomReserve=std::max(px(120),footer+px(28));int y=std::max(top+px(285),h-bottomReserve-2*bh-gap);int buttonWidth=std::min(w-2*pad,px(280*std::sqrt(textScale)));move(find(TAKE_BREAK),(w-buttonWidth)/2,y,buttonWidth,bh);int secondWidth=(buttonWidth-gap)/2;move(find(PAUSE),(w-buttonWidth)/2,y+bh+gap,secondWidth,bh);move(find(RESET),(w-buttonWidth)/2+secondWidth+gap,y+bh+gap,secondWidth,bh);
    int timerTop=navBottom()+px(22);TimerGeometry ring=timerGeometry(w,y);
    int headingHeight=geometry::timerHeaderHeight(int(dpi),textScale),headingTop=timerTop+px(geometry::timerHeaderTopInset);
    auto status=geometry::timerStatusBounds(ring.left,ring.diameter);
    move(find(TIMER_STATE),status.left,headingTop,status.width,headingHeight);
    move(find(COUNT_CAPTION),col.x,timerTop+geometry::timerHeaderCaptionOffset(int(dpi),textScale),col.width,headingHeight);
    int countTop=ring.top+ring.diameter/3,countHeight=ring.diameter/3,countWidth=timerLabelWidth(ring,countTop,ring.diameter/3);
    move(find(COUNTDOWN),ring.left+(ring.diameter-countWidth)/2,countTop,countWidth,countHeight);
   int size=std::min(px(56*std::sqrt(textScale)),ring.diameter/4);if(size!=countSize){HFONT previous=countFont;countSize=size;countFont=CreateFontW(-size,0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");SendMessageW(find(COUNTDOWN),WM_SETFONT,reinterpret_cast<WPARAM>(countFont),TRUE);if(previous)DeleteObject(previous);}
  }
  if(page==1){int listTop=top+px(135)*int(std::ceil(textScale));int listHeight=std::max(px(80),h-listTop-pad-bh-gap);move(historyList,col.x,listTop,col.width,listHeight);move(find(HISTORY_TOGGLE),col.x,listTop+listHeight+gap,std::max(px(240),col.width-px(150)),bh);move(find(CLEAR_HISTORY),col.x+col.width-px(140),listTop+listHeight+gap,px(140),bh);}
  int pillTop=navBottom()+px(22),pillHeightNow=pillHeight(),pillGap=px(4);
  int pillRows=1;
  {std::vector<int> natural;for(int i=0;i<SECTION_COUNT;++i)natural.push_back(measureWidth(sectionNav[i],windowText(sectionNav[i]))+px(22));
   for(auto&segment:geometry::segmentRows(natural,col.x,col.width,pillGap,px(40))){pillRows=std::max(pillRows,segment.row+1);move(sectionNav[segment.index],segment.x,pillTop+segment.row*(pillHeightNow+pillGap),segment.width,pillHeightNow);}}
  int paneTop=pillTop+pillRows*pillHeightNow+(pillRows-1)*pillGap+px(8);move(settingsPane,col.x,paneTop,col.width,std::max(px(40),h-paneTop-px(12)));
  moveAll(moves,true);layoutSettings();
  // Everything the parent paints itself (ring, headings, hint text, divider) depends on the size, so the whole client area is repainted.
  RedrawWindow(main,nullptr,nullptr,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN);
 }
 // Computes content-space geometry once per layout; scrolling only re-applies the offset (positionSettings).
 // Rows: headings and hints span the content width; a caption and its field sit side by side when the column is wide
 // enough for every caption in the section, otherwise the caption stacks above its field.
 void layoutSettings(){
  if(!settingsPane)return;
  RECT paneWindow{},pane{};GetWindowRect(settingsPane,&paneWindow);GetClientRect(settingsPane,&pane);
  const int inset=0,shellWidth=int(paneWindow.right-paneWindow.left);
  std::vector<Control*> items;
  for(auto&c:controls)if(c.page==2){bool inSection=c.section==settingsSection;ShowWindow(c.handle,inSection?SW_SHOW:SW_HIDE);if(c.buddySpin)ShowWindow(c.buddySpin,inSection?SW_SHOW:SW_HIDE);if(inSection)items.push_back(&c);}
  std::vector<geometry::FormItem> form;
  for(auto*item:items){geometry::FormItem f;f.kind=item->kind;std::wstring text=windowText(item->handle);f.textWidth=measureWidth(item->handle,text);
   f.textHeight=[this,handle=item->handle,text](int width){return measureHeight(handle,text,width);};f.sameRow=item->sameRow;f.indent=item->indent;f.spin=item->buddySpin!=nullptr;f.keep=item->keep;
   // Inline rows: time fields fit "00:00" plus their margins and frame, buttons fit their caption, labels their text.
   if(f.kind==Kind::Inline){wchar_t cls[16]{};GetClassNameW(item->handle,cls,16);if(_wcsicmp(cls,L"Edit")==0)f.width=measureWidth(item->handle,L"00:00")+px(30);else if(item->id==WORK_ACCENT_SWATCH||item->id==BREAK_ACCENT_SWATCH)f.width=px(116);else if(_wcsicmp(cls,L"Button")==0)f.width=std::max(px(76),f.textWidth+px(32));else f.width=f.textWidth+px(2);}
   form.push_back(std::move(f));}
  // Pass 1 lays the form out across the whole shell. Only if it is taller than the viewport does a scroll bar appear (inside the
  // shell, at its right edge) and the form is laid out again in the narrower client area. A taller form can never need less, so
  // there is no flip-flop.
  auto placed=geometry::layoutForm(form,std::max(px(200),shellWidth),inset,int(dpi),textScale);
  int y=placed.height;
  {SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE,0,std::max(0,y+px(16)-1),UINT(std::max(1L,pane.bottom)),0,0};SetScrollInfo(settingsPane,SB_VERT,&info,TRUE);}
  RECT afterBar{};GetClientRect(settingsPane,&afterBar);
  if(afterBar.right!=shellWidth){placed=geometry::layoutForm(form,std::max(px(200),int(afterBar.right)),inset,int(dpi),textScale);y=placed.height;}
  for(std::size_t i=0;i<items.size();++i){auto&c=*items[i];auto&b=placed.boxes[i];c.x=b.x;c.y=b.y;c.w=b.w;c.h=b.h;c.rowHeight=b.h;c.spinWidth=b.spinWidth;}
  settingsHeight=y+px(16);settingsScroller.setRange(std::max(0,settingsHeight-int(pane.bottom)));positionSettings(true);
 }
 // Moves every settings control to its cached position minus the scroll offset in one batch and syncs the scroll bar.
 void positionSettings(bool force=false){
  if(!settingsPane)return;
  int offset=settingsScroller.pixel();if(!force&&offset==settingsApplied)return;settingsApplied=offset;
  std::vector<Placement> items;for(auto&c:controls)if(c.page==2&&c.section==settingsSection){items.push_back({c.handle,c.x,c.y-offset,c.w,c.h});if(c.buddySpin)items.push_back({c.buddySpin,c.x+c.w,c.y-offset,c.spinWidth,c.rowHeight});}
  moveAll(items,force);RECT pane{};GetClientRect(settingsPane,&pane);
  SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS,0,std::max(0,settingsHeight-1),UINT(std::max(1L,pane.bottom)),offset,0};SetScrollInfo(settingsPane,SB_VERT,&info,TRUE);
 }
 // `fresh` = a real layout change (size or position changed): the windows are repainted completely at their new places. Scrolling passes
 // keep the cheaper copy-bits behaviour.
 static void moveAll(const std::vector<Placement>&items,bool fresh=false){
  if(items.empty())return;
  HDWP batch=BeginDeferWindowPos(int(items.size()));
  for(auto&i:items){if(!batch)break;batch=DeferWindowPos(batch,i.handle,nullptr,i.x,i.y,i.w,i.h,SWP_NOZORDER|SWP_NOACTIVATE|(fresh?SWP_NOCOPYBITS:0));}
  if(batch){EndDeferWindowPos(batch);return;}
  for(auto&i:items)SetWindowPos(i.handle,nullptr,i.x,i.y,i.w,i.h,SWP_NOZORDER|SWP_NOACTIVATE|(fresh?SWP_NOCOPYBITS:0));
 }
 static bool animationsOn(){BOOL on=TRUE;SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&on,0);return on!=FALSE;}
 // Windows' "lines per wheel notch" setting; WHEEL_PAGESCROLL means one page per notch.
 static double wheelAmount(double pageAmount,double unit){UINT lines=3;SystemParametersInfoW(SPI_GETWHEELSCROLLLINES,0,&lines,0);return lines==WHEEL_PAGESCROLL?pageAmount:double(lines)*unit;}
 void startScroll(){if(scrollTimer||!main)return;scrollClock=monotonic();scrollTimer=SetTimer(main,SCROLL,16,nullptr)!=0;}
 // One timer serves every active animation and stops as soon as all of them have reached their targets.
 void stepScroll(){
  double now=monotonic(),elapsed=now-scrollClock;scrollClock=now;bool more=false;
  if(settingsScroller.animating()){bool again=settingsScroller.step(elapsed);positionSettings();more=more||again;}
  if(breakScroller.animating()){bool again=breakScroller.step(elapsed);positionBreak();more=more||again;}
  if(historyScroller.animating()){bool again=historyScroller.step(elapsed);applyHistory();more=more||again;}
  if(!more){KillTimer(main,SCROLL);scrollTimer=false;}
 }
 void settleScroll(){settingsScroller.finish();breakScroller.finish();historyScroller.finish();positionSettings();positionBreak();applyHistory();if(scrollTimer){KillTimer(main,SCROLL);scrollTimer=false;}}
 void settingsMoved(){positionSettings();if(settingsScroller.animating())startScroll();}
 void breakMoved(){positionBreak();if(breakScroller.animating())startScroll();}
 void historyMoved(){applyHistory();if(historyScroller.animating())startScroll();}
 // Native scroll bar messages: arrows, track clicks and keys ease briefly; dragging the thumb follows the pointer exactly.
 bool barScroll(ScrollModel&model,HWND hwnd,WORD code,int line){
  SCROLLINFO info{sizeof(info),SIF_ALL,0,0,0,0,0};GetScrollInfo(hwnd,SB_VERT,&info);bool animate=animationsOn();
  switch(code){case SB_LINEUP:model.scrollBy(-line,animate);break;case SB_LINEDOWN:model.scrollBy(line,animate);break;case SB_PAGEUP:model.scrollBy(-double(info.nPage),animate);break;case SB_PAGEDOWN:model.scrollBy(double(info.nPage),animate);break;
   case SB_TOP:model.scrollTo(0,animate);break;case SB_BOTTOM:model.scrollTo(model.maximum(),animate);break;case SB_THUMBTRACK:case SB_THUMBPOSITION:model.jump(info.nTrackPos);break;default:return false;}
  return true;
 }
 void wheelSettings(int delta){RECT r{};GetClientRect(settingsPane,&r);settingsScroller.wheel(delta,wheelAmount(r.bottom*0.9,px(20)),animationsOn());settingsMoved();}
 void wheelBreak(int delta){if(!breakWindow)return;RECT r{};GetClientRect(breakWindow,&r);int unit=MulDiv(20,int(GetDpiForWindow(breakWindow)),96);breakScroller.wheel(delta,wheelAmount(r.bottom*0.9,unit),animationsOn());breakMoved();}
 // The list view scrolls in whole rows (a Win32 limit), so its model counts rows and fractional wheel input accumulates.
 int historyRowHeight(){RECT r{};if(historyList&&ListView_GetItemCount(historyList)>0&&ListView_GetItemRect(historyList,0,&r,LVIR_BOUNDS))return std::max(1,int(r.bottom-r.top));return 0;}
 void applyHistory(){
  int rows=historyRowHeight();if(!rows)return;int want=historyScroller.pixel(),top=ListView_GetTopIndex(historyList);
  if(want!=top)ListView_Scroll(historyList,0,(want-top)*rows);
  historyApplied=ListView_GetTopIndex(historyList);if(want>top&&historyApplied<want)historyScroller.setRange(historyApplied);
 }
 void wheelHistory(int delta){
  if(!historyList)return;
  int count=ListView_GetItemCount(historyList),perPage=ListView_GetCountPerPage(historyList);if(count<=0)return;
  historyScroller.setRange(std::max(0,count-perPage));int top=ListView_GetTopIndex(historyList);if(top!=historyApplied)historyScroller.jump(top);
  historyScroller.wheel(delta,wheelAmount(std::max(1,perPage-1),1.0),animationsOn());historyMoved();
 }
 // True when the wheel message was consumed. Windows delivers wheel input to the focused window, so the target is chosen by
 // pointer position; an open drop-down list keeps its own wheel handling.
 bool handleWheel(const MSG&m){
  int delta=GET_WHEEL_DELTA_WPARAM(m.wParam);
  if(!delta||!m.hwnd)return false;
  wchar_t name[32]{};GetClassNameW(m.hwnd,name,32);
  if(wcscmp(name,L"ComboBox")==0&&SendMessageW(m.hwnd,CB_GETDROPPEDSTATE,0,0))return false;
  if(breakWindow&&(m.hwnd==breakWindow||IsChild(breakWindow,m.hwnd))){wheelBreak(delta);return true;}
  if(m.hwnd!=main&&!IsChild(main,m.hwnd))return false;
  POINT point{GET_X_LPARAM(m.lParam),GET_Y_LPARAM(m.lParam)};
  auto over=[&](HWND window){RECT r{};return window&&IsWindowVisible(window)&&GetWindowRect(window,&r)&&PtInRect(&r,point);};
  if(page==2&&over(settingsPane)){wheelSettings(delta);return true;}
  if(page==1&&over(historyList)){wheelHistory(delta);return true;}
  return false;
 }
 // Keyboard focus changes bring the focused control into view, relative to the scroll target.
 void ensureFocused(HWND h){
  if(page!=2||!h||!settingsPane)return;
  RECT client{};GetClientRect(settingsPane,&client);
  for(auto&c:controls)if(c.page==2&&(c.handle==h||c.buddySpin==h||IsChild(c.handle,h))){
   double top=c.y-px(8),bottom=c.y+c.rowHeight+px(8),view=client.bottom;
   if(top<settingsScroller.target())settingsScroller.scrollTo(top,animationsOn());else if(bottom>settingsScroller.target()+view)settingsScroller.scrollTo(bottom-view,animationsOn());else return;
   settingsMoved();return;}
 }
 void ensureBreakVisible(HWND h){
  if(!breakWindow||!h||!IsChild(breakWindow,h))return;
  RECT client{};GetClientRect(breakWindow,&client);int margin=MulDiv(8,int(GetDpiForWindow(breakWindow)),96);
  for(auto&i:breakItems)if(i.handle==h){
   double top=i.y-margin,bottom=i.y+i.h+margin,view=client.bottom;
   if(top<breakScroller.target())breakScroller.scrollTo(top,animationsOn());else if(bottom>breakScroller.target()+view)breakScroller.scrollTo(bottom-view,animationsOn());else return;
   breakMoved();return;}
 }
 void text(HDC dc,const std::wstring&str,RECT area,HFONT font,COLORREF color,UINT flags=DT_LEFT|DT_WORDBREAK){SelectObject(dc,font);SetTextColor(dc,color);SetBkMode(dc,TRANSPARENT);DrawTextW(dc,str.c_str(),int(str.size()),&area,flags);}
 std::wstring timerFooterText()const{return L"20 min · Work      20 ft · Look away      20 sec · Rest\nYour schedule: "+std::to_wstring(settings.workMinutes)+L" min work, "+std::to_wstring(settings.breakSeconds)+L" sec rest.";}
 int timerFooterTextHeight(int width){
  if(!main||!normalFont)return px(40*textScale);
  HDC dc=GetDC(main);if(!dc)return px(40*textScale);
  auto previous=SelectObject(dc,normalFont);const auto value=timerFooterText();RECT bounds{0,0,std::max(1,width),0};
  DrawTextW(dc,value.c_str(),int(value.size()),&bounds,DT_CALCRECT|DT_WORDBREAK|DT_NOPREFIX);
  SelectObject(dc,previous);ReleaseDC(main,dc);return std::max(px(40*textScale),int(bounds.bottom-bounds.top));
 }
 int minimumTimerClientHeight(){
  const int timerTop=navBottom()+px(22),minimumRing=px(150),buttonGap=px(12);
  const int buttonHeight=px(std::max(36.0,30.0*textScale)),buttonGroup=2*buttonHeight+buttonGap;
  const int footer=timerFooterTextHeight(px(460)),bottomReserve=std::max(px(120),footer+px(28));
  const int actionTop=std::max(navBottom()+px(28)+px(285),timerTop+px(88)+px(18)+minimumRing);
  return actionTop+buttonGroup+bottomReserve;
 }
 void paint(HWND hwnd,bool isBreak){
  PAINTSTRUCT ps{};HDC target=BeginPaint(hwnd,&ps);RECT r{};GetClientRect(hwnd,&r);HDC dc=CreateCompatibleDC(target);HBITMAP bitmap=CreateCompatibleBitmap(target,std::max(1L,r.right),std::max(1L,r.bottom));auto previous=SelectObject(dc,bitmap);FillRect(dc,&r,backgroundBrush);
  if(!isBreak){Column col=column(r.right);int rule=std::max(1,px(1));RECT line{col.x,navBottom()-rule,col.x+col.width,navBottom()};HBRUSH lineBrush=CreateSolidBrush(colors.line);FillRect(dc,&line,lineBrush);DeleteObject(lineBrush);}
  if(isBreak){ // Native STATIC controls render all break content.
  }else if(page==0){
    int top=navBottom()+px(22);Column col=column(r.right);RECT title{col.x,top+px(geometry::timerHeaderTopInset),col.x+px(geometry::timerHeaderTitleWidth),top+px(geometry::timerHeaderTopInset)+geometry::timerHeaderHeight(int(dpi),textScale)};text(dc,L"Timer",title,headingFont,colors.foreground,DT_LEFT|DT_VCENTER|DT_SINGLELINE);
   RECT button{};GetWindowRect(find(TAKE_BREAK),&button);MapWindowPoints(nullptr,main,reinterpret_cast<POINT*>(&button),2);TimerGeometry ring=timerGeometry(int(r.right),button.top);
    Gdiplus::Graphics graphics(dc);graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);drawTimerRing(graphics,ring,timerPresentation.progress);
   RECT reset{};GetWindowRect(find(RESET),&reset);MapWindowPoints(nullptr,main,reinterpret_cast<POINT*>(&reset),2);
   const int infoTop=reset.bottom+px(8);RECT rule{col.x,infoTop,col.x+col.width,infoTop+timerFooterTextHeight(col.width)};
   text(dc,timerFooterText(),rule,normalFont,colors.secondary,DT_CENTER|DT_WORDBREAK);
  }else if(page==1){int top=navBottom()+px(28);Column col=column(r.right);RECT title{col.x,top,col.x+col.width,top+px(42)};text(dc,L"History",title,titleFont,colors.foreground);
   std::time_t stamp=std::time_t(utc());std::tm tm{};localtime_s(&tm,&stamp);int today=calendarDay(stamp);auto stats=statistics(history,today,today-(tm.tm_wday+6)%7,calendarDay);
   std::wstring summary=history.empty()?L"No breaks recorded yet.\nCompleted eye breaks will appear here.":L"Today: "+std::to_wstring(stats.todayCompleted)+L" completed · "+std::to_wstring(stats.todaySkipped)+L" skipped · "+std::to_wstring(int(std::round(stats.completion)))+L"% completed\nThis week: "+std::to_wstring(stats.weekCompleted)+L" completed · "+std::to_wstring(stats.streak)+L" day streak\nTotal retained: "+std::to_wstring(stats.totalCompleted)+L" completed";
   RECT area{col.x,title.bottom+px(8),col.x+col.width,title.bottom+px(100)*int(std::ceil(textScale))};text(dc,summary,area,normalFont,colors.secondary);
  }
  BitBlt(target,0,0,r.right,r.bottom,dc,0,0,SRCCOPY);SelectObject(dc,previous);DeleteObject(bitmap);DeleteDC(dc);EndPaint(hwnd,&ps);
 }
 // "today at 17:00", "tomorrow at 09:00" or "Monday at 09:00", in the Windows local calendar.
 std::wstring scheduleTime(std::int64_t stamp){auto at=localTime(stamp),today=localTime(utc());std::wstring day=at.day==today.day?L"today":at.day==today.day+1?L"tomorrow":DAY_NAMES[at.weekday()];return day+L" at "+wide(formatClock(at.minute));}
 std::wstring scheduleStatus(){
  if(!settings.schedule.enabled)return L"The operating schedule is off. Reminders run whenever the timer is running.";
  if(!settings.schedule.anyDay())return L"No days are selected, so no automatic reminders will occur.";
  std::int64_t change=engine->scheduleBoundary();
  if(engine->scheduleOpen())return change?L"Active now. Operating hours end "+scheduleTime(change)+L".":std::wstring(L"Active now, around the clock.");
  return change?L"Outside operating hours. Next operating period: "+scheduleTime(change)+L".":std::wstring(L"Outside operating hours.");
 }
 // Manual pause and scheduled inactivity are reported separately; a held countdown is never shown as running.
 std::wstring stateText(const Snapshot&s){
  if(s.paused)return s.held?L"Paused — outside scheduled hours":L"Paused";
  if(s.phase==Phase::Break)return L"Taking an eye break";
  if(s.held){std::int64_t next=engine->scheduleBoundary();return next?L"Outside scheduled hours — next period "+scheduleTime(next):std::wstring(L"Outside scheduled hours");}
  if(s.phase==Phase::Snooze)return L"Snoozed — next reminder below";
  return engine->scheduled()?L"Running — within scheduled hours":L"Running";
 }
 static const wchar_t* captionText(const Snapshot&s){return s.phase==Phase::Break?L"Break time remaining":s.held?L"On hold":L"Next eye break";}
  bool updateAccessibleTimer(){auto snap=engine->snapshot();TimerPresentation next{timeText(snap.remaining),captionText(snap),stateText(snap),snap.progress()};
   bool changed=next.countdown!=timerPresentation.countdown||next.caption!=timerPresentation.caption||next.status!=timerPresentation.status||next.progress!=timerPresentation.progress;timerPresentation=std::move(next);
   auto set=[&](int id,const std::wstring&value){HWND h=find(id);if(!h)return;wchar_t old[160]{};GetWindowTextW(h,old,160);if(value!=old){SetWindowTextW(h,value.c_str());InvalidateRect(h,nullptr,FALSE);}};
   set(COUNTDOWN,timerPresentation.countdown);set(COUNT_CAPTION,timerPresentation.caption);set(TIMER_STATE,timerPresentation.status);return changed;}
  void refreshTimerDisplay(bool tickEngine=true){
   if(!engine||quitting)return;
   if(tickEngine)engine->tick();
   bool changed=updateAccessibleTimer();
   if(changed&&!hidden&&page==0)InvalidateRect(main,nullptr,FALSE);
   if(breakWindow){HWND count=GetDlgItem(breakWindow,COUNTDOWN);if(count){wchar_t previous[32]{};GetWindowTextW(count,previous,32);if(timerPresentation.countdown!=previous){SetWindowTextW(count,timerPresentation.countdown.c_str());InvalidateRect(breakWindow,nullptr,FALSE);}}}
  }
 void updateScheduleStatus(){HWND h=find(SCHEDULE_STATUS);if(!h)return;auto text=scheduleStatus();if(text==windowText(h))return;SetWindowTextW(h,text.c_str());if(page==2&&settingsSection==SCHEDULE_SECTION)layoutSettings();}
 // Wall-clock or time-zone change (announced by Windows, or found by the once-a-minute check): re-evaluate the schedule.
 void timeChanged(){if(!engine||quitting)return;engine->tick();schedule();updateAccessibleTimer();updateScheduleStatus();updateTray();if(!hidden&&page==0)InvalidateRect(main,nullptr,FALSE);}
 void updateHistory(){if(!historyList)return;ListView_DeleteAllItems(historyList);historyScroller.jump(0);historyApplied=0;int row=0;for(auto it=history.rbegin();it!=history.rend()&&row<100;++it,++row){auto date=formatDate(it->at);LVITEMW item{};item.mask=LVIF_TEXT;item.iItem=row;item.pszText=date.data();ListView_InsertItem(historyList,&item);ListView_SetItemText(historyList,row,1,const_cast<LPWSTR>(it->completed?L"Completed":L"Skipped"));auto seconds=std::to_wstring(int(std::round(it->seconds)));ListView_SetItemText(historyList,row,2,seconds.data());}InvalidateRect(main,nullptr,TRUE);}
 void addTray(){trayData={};trayData.cbSize=sizeof(trayData);trayData.hWnd=main;trayData.uID=1;trayData.uFlags=NIF_ICON|NIF_MESSAGE|NIF_TIP|NIF_SHOWTIP;trayData.uCallbackMessage=TRAY_MESSAGE;trayData.hIcon=icon;wcscpy_s(trayData.szTip,L"Eye Break Reminder");trayAdded=Shell_NotifyIconW(NIM_ADD,&trayData)!=0;if(trayAdded){trayData.uVersion=NOTIFYICON_VERSION_4;Shell_NotifyIconW(NIM_SETVERSION,&trayData);}}
 void updateTray(){auto s=engine->snapshot();auto status=s.paused?(s.held?L"Paused, outside scheduled hours":L"Paused"):s.phase==Phase::Break?L"Taking an eye break":s.held?L"Outside scheduled hours":s.phase==Phase::Snooze?L"Snoozed":L"Running";auto tip=L"Eye Break Reminder — "+std::wstring(status);wcsncpy_s(trayData.szTip,tip.c_str(),_TRUNCATE);trayData.uFlags=NIF_TIP|NIF_SHOWTIP;if(trayAdded)Shell_NotifyIconW(NIM_MODIFY,&trayData);}
 void clearNotification(){if(!trayAdded)return;trayData.uFlags=NIF_INFO;trayData.szInfo[0]=0;Shell_NotifyIconW(NIM_MODIFY,&trayData);}
 void notify(std::uint64_t cycle){if(!settings.notifications||!trayAdded||notifiedCycle==cycle)return;notifiedCycle=cycle;trayData.uFlags=NIF_INFO|NIF_REALTIME;wcscpy_s(trayData.szInfoTitle,L"Time to rest your eyes");auto message=L"Look 20 feet / 6 metres away for "+std::to_wstring(settings.breakSeconds)+L" seconds. Click to open the reminder.";wcsncpy_s(trayData.szInfo,message.c_str(),_TRUNCATE);trayData.dwInfoFlags=NIIF_INFO|NIIF_NOSOUND|NIIF_RESPECT_QUIET_TIME;Shell_NotifyIconW(NIM_MODIFY,&trayData);}
 void trayMenu(POINT anchor){
  if(IsWindowVisible(trayMenuOwner))return;
  auto s=engine->snapshot();HMENU menu=CreatePopupMenu();if(!menu)return;
  AppendMenuW(menu,MF_STRING,1,L"Open Eye Break Reminder");AppendMenuW(menu,MF_STRING,2,s.paused?L"Resume timer":L"Pause timer");AppendMenuW(menu,MF_STRING|(s.phase==Phase::Break?MF_GRAYED:0),3,L"Take a break now");AppendMenuW(menu,MF_STRING|(settings.alarm?MF_CHECKED:0),4,settings.alarm?L"Alarm on":L"Alarm muted");AppendMenuW(menu,MF_STRING,5,L"Settings");AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,6,L"Exit");
  // Capture the icon bounds before foreground activation closes the overflow panel.
  NOTIFYICONIDENTIFIER identity{};identity.cbSize=sizeof(identity);identity.hWnd=main;identity.uID=trayData.uID;
  RECT iconBounds{};bool haveIcon=SUCCEEDED(Shell_NotifyIconGetRect(&identity,&iconBounds));
  if(anchor.x==-1&&anchor.y==-1){if(haveIcon)anchor={iconBounds.left,iconBounds.top};else GetCursorPos(&anchor);}
  // A hidden main window cannot reliably own the foreground menu. Use a visible,
  // zero-size tool window that is topmost only for the lifetime of this menu.
  SetWindowPos(trayMenuOwner,HWND_TOPMOST,anchor.x,anchor.y,0,0,SWP_SHOWWINDOW);
  SetForegroundWindow(trayMenuOwner);
  int gap=int(8*GetDpiForWindow(trayMenuOwner)/96);TPMPARAMS parameters{};parameters.cbSize=sizeof(parameters);
  UINT flags=TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON|TPM_BOTTOMALIGN|TPM_VERTICAL;
  bool rightAligned=GetSystemMetrics(SM_MENUDROPALIGNMENT)!=0;if(rightAligned)flags|=TPM_RIGHTALIGN;
  if(haveIcon){parameters.rcExclude=iconBounds;InflateRect(&parameters.rcExclude,gap,gap);anchor.x=rightAligned?iconBounds.right:iconBounds.left;anchor.y=parameters.rcExclude.top;}
  int chosen=int(TrackPopupMenuEx(menu,flags,anchor.x,anchor.y,trayMenuOwner,haveIcon?&parameters:nullptr));
  DestroyMenu(menu);PostMessageW(trayMenuOwner,WM_NULL,0,0);ShowWindow(trayMenuOwner,SW_HIDE);
  SetWindowPos(trayMenuOwner,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
  // Return focus to the tray only when the command doesn't open an app window.
  if(chosen!=1&&chosen!=3&&chosen!=5&&chosen!=6)Shell_NotifyIconW(NIM_SETFOCUS,&trayData);
  switch(chosen){case 1:showMain();break;case 2:togglePause();break;case 3:engine->takeBreak();break;case 4:settings.alarm=!settings.alarm;if(!settings.alarm)audio->stop();settingsChanged();if(page==2)buildSettings();break;case 5:switchPage(2);buildSettings();showMain(false);SetFocus(nav[2]);break;case 6:exit();break;}
 }
 void togglePause(){if(engine->snapshot().paused)engine->resume();else {engine->pause();audio->stop();}}
 void settingsChanged(){settings.validate();engine->configure(settings);dirtySettings=true;applyTheme();updateTray();updateScheduleStatus();InvalidateRect(main,nullptr,TRUE);}
 void persistAccentPreferences(){applyTheme();saveSettings();InvalidateRect(main,nullptr,TRUE);if(breakWindow)InvalidateRect(breakWindow,nullptr,TRUE);}
 void chooseAccentColor(bool work){
  auto pendingColors=pickerCustomColors;CHOOSECOLORW picker{};picker.lStructSize=sizeof(picker);picker.hwndOwner=main;picker.lpCustColors=pendingColors.data();picker.rgbResult=accentSwatch(work);picker.Flags=CC_FULLOPEN|CC_RGBINIT|CC_ANYCOLOR;
  if(!ChooseColorW(&picker))return;
  pickerCustomColors=pendingColors;for(std::size_t i=0;i<pickerCustomColors.size();++i)settings.pickerCustomColors[i]=theme::rgb(GetRValue(pickerCustomColors[i]),GetGValue(pickerCustomColors[i]),GetBValue(pickerCustomColors[i]));theme::Color selected=theme::rgb(GetRValue(picker.rgbResult),GetGValue(picker.rgbResult),GetBValue(picker.rgbResult));
  if(work){settings.customWorkAccent=true;settings.workAccentColor=selected;}
  else{settings.customBreakAccent=true;settings.breakAccentColor=selected;}
  persistAccentPreferences();
 }
 void resetAccentColors(){if(!settings.customWorkAccent&&!settings.customBreakAccent)return;settings.customWorkAccent=false;settings.customBreakAccent=false;persistAccentPreferences();}
 // Rebuilds the Settings controls after periods are added, removed or replaced, then focuses `focusId`.
 void rebuildSettings(int focusId){
  SendMessageW(settingsPane,WM_SETREDRAW,FALSE,0);buildSettings();SendMessageW(settingsPane,WM_SETREDRAW,TRUE,0);
  RedrawWindow(settingsPane,nullptr,nullptr,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_FRAME);if(HWND h=find(focusId))SetFocus(h);
 }
 // A typed time is stored only when it forms a valid period; otherwise the field shows the stored value again and explains why.
 void commitTime(int day,int period,bool end){
  HWND h=find(PERIOD_BASE+day*10+period*3+(end?1:0));if(!h||period>=settings.schedule.counts[day])return;
  Period&p=settings.schedule.periods[day][period];Period next=p;int typed=0;
  bool readable=parseClock(utf8(windowText(h)),end,typed),valid=readable&&makePeriod(end?p.start:typed,end?typed:p.end,next);
  if(valid&&!(next==p)){p=next;settingsChanged();saveSettings();}
  SetWindowTextW(h,wide(formatClock(end?p.end:p.start)).c_str());
  if(!valid){EDITBALLOONTIP tip{sizeof(tip),L"Time not changed",readable?L"Start and end can't be the same. For a whole day, use 00:00 to 24:00.":end?L"Enter a 24-hour time such as 17:30. Use 24:00 for midnight at the end of the day.":L"Enter a 24-hour time such as 09:00 or 13:30.",TTI_WARNING};Edit_ShowBalloonTip(h,&tip);}
 }
 void addPeriod(int day){
  auto&s=settings.schedule;if(s.counts[day]>=Schedule::maxPeriods)return;
  // The new period starts an hour after the previous one ends and lasts up to four hours; it can be edited at once.
  const Period&last=s.periods[day][s.counts[day]-1];int start=(last.end+60)%1440;s.periods[day][s.counts[day]++]=Period{start,std::min(start+240,1440)};
  settingsChanged();saveSettings();rebuildSettings(PERIOD_BASE+day*10+(s.counts[day]-1)*3);
 }
 void removePeriod(int day,int period){
  auto&s=settings.schedule;if(s.counts[day]<=1||period>=s.counts[day])return;
  std::copy(s.periods[day].begin()+period+1,s.periods[day].begin()+s.counts[day],s.periods[day].begin()+period);s.periods[day][--s.counts[day]]=Period{};
  settingsChanged();saveSettings();rebuildSettings(PERIOD_BASE+day*10+std::min(period,s.counts[day]-1)*3);
 }
 void applyPreset(bool everyDay){
  Schedule preset=Schedule::preset(everyDay);
  if(!settings.schedule.sameHours(preset)&&!confirm(main,L"Replace the weekly hours?",everyDay?L"Every day will run from 09:00 to 17:00. Your current days and periods are replaced.":L"Monday to Friday will run from 09:00 to 17:00, and Saturday and Sunday are turned off. Your current days and periods are replaced.",colors.dark,colors.systemContrast))return;
  preset.enabled=settings.schedule.enabled;settings.schedule=preset;settingsChanged();saveSettings();rebuildSettings(everyDay?PRESET_EVERYDAY:PRESET_WEEKDAYS);
 }
 bool scheduleCommand(int id,int code){
  if(id>=DAY_BASE&&id<DAY_BASE+7){if(code==BN_CLICKED){settings.schedule.days[id-DAY_BASE]=checked(id);enableDay(id-DAY_BASE);settingsChanged();saveSettings();}return true;}
  if(id<PERIOD_BASE||id>=PERIOD_END)return false;
  int day=(id-PERIOD_BASE)/10,slot=(id-PERIOD_BASE)%10;
  if(slot==9){if(code==BN_CLICKED)addPeriod(day);return true;}
  if(slot>=9)return true;
  int period=slot/3,part=slot%3;
  if(part==2&&code==BN_CLICKED)removePeriod(day,period);
  else if(part<2&&code==EN_KILLFOCUS)commitTime(day,period,part==1);
  return true;
 }
 int selected(int id){return int(SendMessageW(find(id),CB_GETCURSEL,0,0));}
 bool checked(int id){return SendMessageW(find(id),BM_GETCHECK,0,0)==BST_CHECKED;}
 int integer(int id,int previous){wchar_t text[32]{};GetWindowTextW(find(id),text,32);if(!*text)return previous;wchar_t*end=nullptr;long value=wcstol(text,&end,10);return *end?previous:int(std::clamp(value,0L,10000L));}
 void command(int id,int code){
  if(loading)return;
  if(code==EN_SETFOCUS||code==CBN_SETFOCUS||code==BN_SETFOCUS)ensureFocused(find(id));
  if(id>=NAV_TIMER&&id<=NAV_SETTINGS&&code==BN_CLICKED){switchPage(id-NAV_TIMER);return;}
  if(id>=SECTION_BASE&&id<SECTION_BASE+SECTION_COUNT&&code==BN_CLICKED){selectSection(id-SECTION_BASE);return;}
  if(scheduleCommand(id,code))return;
  if(code==BN_CLICKED){switch(id){
   case UPDATE_CHECK:startUpdateCheck();return;case UPDATE_OPEN:openOfficialRelease();return;
   case CHOOSE_WORK_ACCENT:chooseAccentColor(true);return;case CHOOSE_BREAK_ACCENT:chooseAccentColor(false);return;case RESET_ACCENT_COLORS:resetAccentColors();return;
   case PRESET_WEEKDAYS:applyPreset(false);return;case PRESET_EVERYDAY:applyPreset(true);return;
   case SCHEDULE_TOGGLE:settings.schedule.enabled=checked(id);break;case PAUSE:togglePause();return;case RESET:engine->reset();return;case TAKE_BREAK:engine->takeBreak();return;case COMPLETE:engine->finish(true);return;case SKIP:engine->finish(false);return;case SNOOZE1:engine->snooze(1);return;case SNOOZE3:engine->snooze(3);return;case SNOOZE5:engine->snooze(5);return;
   case CLEAR_HISTORY:if(confirm(main,L"Clear all history?",L"This removes every eye break recorded on this device.",colors.dark,colors.systemContrast)){history.clear();saveHistory();updateHistory();}return;
   case PREVIEW:if(!audio->play(settings,true))error(L"The alarm couldn't play. Check your Windows audio output.");return;
   case STOP_AUDIO:audio->stop();return;
   case RESET_SETTINGS:if(confirm(main,L"Reset all settings?",L"Restores defaults, turns the operating schedule off and disables Start with Windows. Your history is preserved.",colors.dark,colors.systemContrast)){if(!setStartup(false)){error(L"Startup registration couldn't be removed.");return;}settings={};settingsChanged();engine->reset();saveSettings();buildSettings();}return;
   case HISTORY_TOGGLE:settings.history=checked(id);break;case ALARM_TOGGLE:settings.alarm=checked(id);if(!settings.alarm)audio->stop();break;case REPEAT:settings.repeat=checked(id);break;case NOTIFY:settings.notifications=checked(id);if(!settings.notifications)clearNotification();break;case SNOOZE:settings.snooze=checked(id);break;case BREAK_COLORS:settings.breakModeColors=checked(id);break;case AUTO_START:settings.autoStart=checked(id);break;case TRAY:settings.tray=checked(id);break;case RESTORE:settings.restore=checked(id);break;case PAUSE_LOCK:settings.pauseLocked=checked(id);break;
   case STARTUP:{bool requested=checked(id);if(!setStartup(requested)){SendMessageW(find(id),BM_SETCHECK,settings.startup?BST_CHECKED:BST_UNCHECKED,0);error(L"Startup couldn't be changed. Your organisation may manage startup apps.");return;}settings.startup=requested;break;}default:return;}}
  else if(code==CBN_SELCHANGE){switch(id){case SOUND:settings.sound=selected(id);break;case MODE:settings.mode=selected(id);break;case MONITOR:settings.monitor=selected(id);break;case THEME:settings.theme=selected(id);break;case SELECT_MONITOR:{int index=selected(id);if(index>=0&&index<int(displays.size()))settings.selectedMonitor=utf8(displays[index].device);break;}default:return;}}
  else if(code==EN_KILLFOCUS&&(id==WORK||id==BREAK_SECONDS)){if(id==WORK)settings.workMinutes=integer(id,settings.workMinutes);else settings.breakSeconds=integer(id,settings.breakSeconds);settings.validate();SetWindowTextW(find(id),std::to_wstring(id==WORK?settings.workMinutes:settings.breakSeconds).c_str());}
  else return;
  settingsChanged();saveSettings();
 }
 void captureBounds(){if(!main||IsIconic(main)||IsZoomed(main)||hidden)return;RECT r{};GetWindowRect(main,&r);settings.x=r.left;settings.y=r.top;settings.width=int((r.right-r.left)*96/dpi);settings.height=int((r.bottom-r.top)*96/dpi);settings.validate();normalBounds=r;haveNormalBounds=true;}
 void showMain(bool focusBreak=true){hidden=false;ShowWindow(main,IsIconic(main)?SW_RESTORE:SW_SHOW);updateAccessibleTimer();InvalidateRect(main,nullptr,FALSE);SetForegroundWindow(main);updateRenderTimer();if(focusBreak&&engine->snapshot().phase==Phase::Break){if(!breakWindow)showBreak();else SetForegroundWindow(breakWindow);}}
 void hideMain(){if(!trayAdded){error(L"The tray icon isn't available. The window will stay open so you can control the timer.");ShowWindow(main,SW_RESTORE);return;}captureBounds();hidden=true;ShowWindow(main,SW_HIDE);saveSettings();saveTimer();updateRenderTimer();}
 void closeMain(){if(!settings.tray){exit();return;}if(!settings.trayExplained){settings.trayExplained=true;saveSettings();inform(main,L"The timer keeps running in the system tray",L"Closing keeps your reminders active. To quit, right-click the tray icon and choose Exit. You can change this in Settings.",colors.dark,colors.systemContrast);}hideMain();}
  void updateRenderTimer(){
   if(!main)return;
   UINT interval=0;
   if(engine){auto s=engine->snapshot();if(!s.paused&&!(s.held&&s.phase!=Phase::Break)&&((!hidden&&!IsIconic(main)&&page==0)||breakWindow)){BOOL animations=TRUE;SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&animations,0);interval=animations?250:1000;}}
   InterlockedExchange(&resizeVisualInterval,LONG(interval));
   if(interval==renderTimerInterval)return;
   if(renderTimerInterval){KillTimer(main,RENDER);renderTimerInterval=0;}
   if(interval&&SetTimer(main,RENDER,interval,nullptr))renderTimerInterval=interval;
  }
 // The worker wakes for whichever comes first: the countdown reaching zero or the next operating-schedule boundary. Boundaries are
 // wall-clock instants, so with the schedule on the deadline is also re-derived at least once a minute; a clock or time-zone change
 // that Windows does not announce cannot leave a hidden window in the wrong state for long. The engine checks the schedule before
 // a due countdown can start a break.
 void schedule(){
  auto s=engine->snapshot();double now=monotonic(),next=0;bool away=engine->isSuspended();
  if(!away&&!s.paused&&!(s.held&&s.phase!=Phase::Break))next=now+s.remaining;
  if(!away&&engine->scheduled()){double boundary=now+60;if(std::int64_t change=engine->scheduleBoundary())boundary=std::min(boundary,now+std::max(0.0,double(change)-preciseUtc())+0.02);next=next>0?std::min(next,boundary):boundary;}
  EnterCriticalSection(&deadlineLock);deadline=next;LeaveCriticalSection(&deadlineLock);SetEvent(dueEvent);
 }
  static DWORD WINAPI work(LPVOID context){auto self=static_cast<Application*>(context);HANDLE events[]={self->stopEvent,self->dueEvent};double nextVisual=0,clockScale=1.0;
#ifdef EYEBREAK_TEST_BUILD
   clockScale=monotonicScale;
#endif
   for(;;){EnterCriticalSection(&self->deadlineLock);double when=self->deadline;LeaveCriticalSection(&self->deadlineLock);
   LONG interval=InterlockedCompareExchange(&self->resizeVisualInterval,0,0);bool resizing=InterlockedCompareExchange(&self->interactiveResize,0,0)!=0&&interval>0;double now=monotonic();if(resizing){if(nextVisual<=0)nextVisual=now+interval/1000.0*clockScale;}else nextVisual=0;
   double wakeAt=when;if(resizing&&(wakeAt<=0||nextVisual<wakeAt))wakeAt=nextVisual;DWORD timeout=wakeAt<=0?INFINITE:DWORD(std::clamp(std::ceil((wakeAt-now)*1000/clockScale),1.0,double(MAXDWORD-1)));
   DWORD result=WaitForMultipleObjects(2,events,FALSE,timeout);if(result==WAIT_OBJECT_0||result==WAIT_FAILED)return 0;if(result==WAIT_TIMEOUT){double after=monotonic();bool due=false;
    if(when>0&&after>=when){EnterCriticalSection(&self->deadlineLock);if(self->deadline==when){self->deadline=0;due=true;}LeaveCriticalSection(&self->deadlineLock);}if(due)PostMessageW(self->main,ENGINE_MESSAGE,0,0);
    LONG currentInterval=InterlockedCompareExchange(&self->resizeVisualInterval,0,0);if(InterlockedCompareExchange(&self->interactiveResize,0,0)!=0&&currentInterval>0&&nextVisual>0&&after>=nextVisual){nextVisual=after+currentInterval/1000.0;if(InterlockedCompareExchange(&self->resizeRefreshPosted,1,0)==0&&!PostMessageW(self->main,RESIZE_REFRESH,0,0))InterlockedExchange(&self->resizeRefreshPosted,0);}}}}
 void changed(){auto snap=engine->snapshot();applyTheme();updateAccessibleTimer();
  if(snap.phase!=Phase::Break)dismissBreak();
  // Operating hours closed during a break the user started: it may finish, but no alarm, notification or snooze outside hours.
  else if(snap.held){if(audio->playing&&!audio->preview)audio->stop();clearNotification();if(breakWindow)for(int id:{SNOOZE1,SNOOZE3,SNOOZE5})if(HWND b=GetDlgItem(breakWindow,id))EnableWindow(b,FALSE);}
  updateScheduleStatus();SetWindowTextW(find(PAUSE),engine->snapshot().paused?L"Resume":L"Pause");schedule();saveTimer();updateTray();updateRenderTimer();InvalidateRect(main,nullptr,TRUE);if(breakWindow){SetWindowTextW(GetDlgItem(breakWindow,BREAK_GUIDANCE),engine->snapshot().paused?L"Break paused. Resume from the main window.":L"Keep looking into the distance.");InvalidateRect(breakWindow,nullptr,TRUE);}}
 // Outside operating hours the only break is one the user asked for: the engine sends it without the alarm and it is not notified.
 void breakDue(std::uint64_t cycle,bool alarm){if(locked||sleeping||engine->isSuspended())return;if(alarm&&!audio->play(settings))error(L"The alarm couldn't play. Check your Windows audio output.");if((hidden||IsIconic(main))&&!engine->snapshot().held)notify(cycle);showBreak();}
 // The completion alarm reuses the selected sound, volume and mute setting. It is asynchronous (waveOut) and keyed to the
 // finished break, so repeated timer messages, repaints, window restores and recovery cannot play it twice.
 void breakCompleted(std::uint64_t cycle,bool alarm){if(!alarm||locked||sleeping||engine->isSuspended()||alarmedCycle==cycle)return;alarmedCycle=cycle;if(!audio->play(settings))error(L"The alarm couldn't play. Check your Windows audio output.");}
 void dismissBreak(){audio->stop();clearNotification();if(breakWindow){quietBreak=true;HWND old=breakWindow;breakWindow=nullptr;DestroyWindow(old);breakItems.clear();quietBreak=false;if(breakFont){DeleteObject(breakFont);breakFont=nullptr;}if(breakTitleFont){DeleteObject(breakTitleFont);breakTitleFont=nullptr;}if(breakCountFont){DeleteObject(breakCountFont);breakCountFont=nullptr;}}updateRenderTimer();}
 void showBreak(){
  if(breakWindow||engine->snapshot().phase!=Phase::Break||locked||sleeping||engine->isSuspended())return;
  auto monitor=preferred(settings,GetForegroundWindow());RECT work=monitor.work;UINT monitorDpi=dpi;
  // Place first, then read the window's actual per-monitor DPI before sizing it.
  DWORD style=settings.mode==2?WS_POPUP|WS_CLIPCHILDREN:WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX|WS_CLIPCHILDREN;
  breakWindow=CreateWindowExW(WS_EX_APPWINDOW,BREAK_CLASS,L"Taking an eye break — Eye Break Reminder",style|WS_VSCROLL,work.left,work.top,100,100,nullptr,nullptr,instance,nullptr);
  if(!breakWindow){error(L"The break reminder couldn't open. Please rest your eyes for 20 seconds.");return;}
  monitorDpi=GetDpiForWindow(breakWindow);breakScroller=ScrollModel();breakApplied=INT_MIN;breakItems.clear();
  auto makeFont=[&](double height,int weight){return CreateFontW(-int(height*monitorDpi/96),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");};
  breakFont=makeFont(14*textScale,FW_NORMAL);breakTitleFont=makeFont(25*textScale,FW_SEMIBOLD);breakCountFont=makeFont(56*std::sqrt(textScale),FW_SEMIBOLD);
  int w=int((settings.mode==1?440:580)*monitorDpi/96),h=int((settings.mode==1?500:580)*monitorDpi/96);
  if(settings.mode==2){work=monitor.bounds;w=work.right-work.left;h=work.bottom-work.top;}else {w=std::min(w,int(work.right-work.left));h=std::min(h,int(work.bottom-work.top));}
  SetWindowPos(breakWindow,nullptr,work.left+(work.right-work.left-w)/2,work.top+(work.bottom-work.top-h)/2,w,h,SWP_NOZORDER);
  SendMessageW(breakWindow,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(icon));SendMessageW(breakWindow,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(icon));
  // Snoozing schedules an automatic reminder, so a break outside operating hours offers no snooze.
  breakSnooze=settings.snooze&&!engine->snapshot().held;
  auto button=[&](const wchar_t* name,int id){HWND child=CreateWindowExW(0,L"BUTTON",name,WS_CHILD|WS_VISIBLE|WS_TABSTOP|(id==COMPLETE?BS_DEFPUSHBUTTON:BS_PUSHBUTTON)|BS_MULTILINE,0,0,0,0,breakWindow,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(breakFont),TRUE);return child;};button(L"I'm back",COMPLETE);button(L"Skip",SKIP);if(breakSnooze){button(L"Snooze 1 min",SNOOZE1);button(L"3 min",SNOOZE3);button(L"5 min",SNOOZE5);}
  auto caption=[&](const wchar_t*name,int id,HFONT font){HWND child=CreateWindowExW(0,L"STATIC",name,WS_CHILD|WS_VISIBLE|SS_CENTER|(id==COUNTDOWN?SS_CENTERIMAGE:0),0,0,1,1,breakWindow,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);};
  caption(L"Taking an eye break",BREAK_TITLE,breakTitleFont);caption(L"Look at something at least 20 feet / 6 metres away.",BREAK_INSTRUCTION,breakFont);caption(timeText(engine->snapshot().remaining).c_str(),COUNTDOWN,breakCountFont);caption(L"Keep looking into the distance.",BREAK_GUIDANCE,breakFont);
  layoutBreak();applyTheme();ShowWindow(breakWindow,SW_SHOW);SetForegroundWindow(breakWindow);FLASHWINFO flash{sizeof(flash),breakWindow,FLASHW_TRAY,3,0};FlashWindowEx(&flash);SetFocus(GetDlgItem(breakWindow,COMPLETE));updateRenderTimer();
 }
 void layoutBreak(){
  // The initial SetWindowPos in showBreak sends WM_SIZE before the reminder's child controls exist.
  // Do not build a deferred-position batch from null HWNDs; Windows leaks a USER object when that batch fails.
  if(!breakWindow||!GetDlgItem(breakWindow,BREAK_TITLE)||!GetDlgItem(breakWindow,COMPLETE))return;
  RECT r{};GetClientRect(breakWindow,&r);int scale=int(GetDpiForWindow(breakWindow));auto bpx=[&](double n){return int(n*scale/96.0);};
  int pad=bpx(28),gap=bpx(12),bh=bpx(40*textScale),width=std::min(bpx(380),int(r.right)-2*pad),x=(r.right-width)/2,y=pad;
  breakItems.clear();
  auto place=[&](int id,int height){breakItems.push_back({GetDlgItem(breakWindow,id),x,y,width,height});y+=height+gap;};
  place(BREAK_TITLE,bpx(42*textScale));place(BREAK_INSTRUCTION,bpx(48*textScale));place(COUNTDOWN,bpx(96*std::sqrt(textScale)));place(BREAK_GUIDANCE,bpx(48*textScale));place(COMPLETE,bh);
  int skipWidth=breakSnooze?width/4:width;breakItems.push_back({GetDlgItem(breakWindow,SKIP),x,y,skipWidth-4,bh});
  if(breakSnooze){int widths[3]={width/3,width/5,width-width/4-width/3-width/5};int left=x+width/4;int ids[3]={SNOOZE1,SNOOZE3,SNOOZE5};for(int i=0;i<3;++i){breakItems.push_back({GetDlgItem(breakWindow,ids[i]),left,y,widths[i]-4,bh});left+=widths[i];}}
  breakHeight=y+bh+pad;breakScroller.setRange(std::max(0,breakHeight-int(r.bottom)));positionBreak(true);InvalidateRect(breakWindow,nullptr,TRUE);
 }
 void positionBreak(bool force=false){
  if(!breakWindow)return;
  int offset=breakScroller.pixel();if(!force&&offset==breakApplied)return;breakApplied=offset;
  std::vector<Placement> items;for(auto&i:breakItems)items.push_back({i.handle,i.x,i.y-offset,i.w,i.h});moveAll(items,force);
  RECT r{};GetClientRect(breakWindow,&r);SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS,0,std::max(0,breakHeight-1),UINT(std::max(1L,r.bottom)),offset,0};SetScrollInfo(breakWindow,SB_VERT,&info,TRUE);
 }
 void suspend(bool isLock){engine->suspend(isLock);dismissBreak();schedule();saveTimer();}
 void wake(){if(locked||sleeping)return;engine->wake();schedule();if(engine->snapshot().phase==Phase::Break)showBreak();}
 void exit(){if(quitting)return;quitting=true;saveSettings();saveTimer();dismissBreak();DestroyWindow(main);}
 LRESULT color(HDC dc,HWND child=nullptr,bool input=false){
  // A disabled edit (the hours of an unselected day) asks for static colours; it keeps its field surface with secondary text.
  bool dimmed=false;if(child&&!input&&!IsWindowEnabled(child)){wchar_t cls[16]{};GetClassNameW(child,cls,16);dimmed=input=_wcsicmp(cls,L"Edit")==0;}
   SetBkColor(dc,input?colors.surface:colors.background);SetBkMode(dc,OPAQUE);
   COLORREF ink=dimmed?colors.secondary:colors.foreground;if(child&&!dimmed){int id=GetDlgCtrlID(child);if(id==TIMER_STATE||id==BREAK_TITLE)ink=accentText();else if(reinterpret_cast<HFONT>(SendMessageW(child,WM_GETFONT,0,0))==headingFont)ink=accentText();else if(id==COUNT_CAPTION||id==BREAK_INSTRUCTION||id==BREAK_GUIDANCE||GetWindowLongPtrW(child,GWLP_USERDATA)==1)ink=colors.secondary;}SetTextColor(dc,ink);return reinterpret_cast<LRESULT>(input?surfaceBrush:backgroundBrush);}
 static LRESULT CALLBACK paneProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_DRAWITEM:return a.drawAccentSwatch(reinterpret_cast<DRAWITEMSTRUCT*>(l))?TRUE:FALSE;case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;case WM_HSCROLL:if(reinterpret_cast<HWND>(l)==a.find(VOLUME)){a.settings.volume=int(SendMessageW(a.find(VOLUME),TBM_GETPOS,0,0));a.updateVolumeLabel();a.settingsChanged();if(LOWORD(w)==TB_ENDTRACK)a.saveSettings();}return 0;case WM_VSCROLL:if(a.barScroll(a.settingsScroller,hwnd,LOWORD(w),a.px(40)))a.settingsMoved();return 0;case WM_MOUSEWHEEL:a.wheelSettings(GET_WHEEL_DELTA_WPARAM(w));return 0;case WM_ERASEBKGND:{RECT r{};GetClientRect(hwnd,&r);FillRect(reinterpret_cast<HDC>(w),&r,a.backgroundBrush);return 1;}case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:case WM_CTLCOLORLISTBOX:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK breakProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:a.paint(hwnd,true);return 0;case WM_ERASEBKGND:return 1;case WM_SIZE:a.layoutBreak();return 0;case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
  case WM_VSCROLL:if(a.barScroll(a.breakScroller,hwnd,LOWORD(w),MulDiv(40,int(GetDpiForWindow(hwnd)),96)))a.breakMoved();return 0;
  case WM_MOUSEWHEEL:a.wheelBreak(GET_WHEEL_DELTA_WPARAM(w));return 0;
  case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CLOSE:if(!a.quietBreak){a.engine->finish(false);return 0;}break;case WM_DPICHANGED:{a.breakScroller.rescale(double(HIWORD(w))/GetDpiForWindow(hwnd));auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.layoutBreak();return 0;}}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK mainProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;
  if(msg==a.activateMessage){a.showMain();return 0;}if(msg==a.quitMessage){a.exit();return 0;}if(msg==a.explorerMessage){a.addTray();a.updateTray();return 0;}
  switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:if(a.engine)a.paint(hwnd,false);else {PAINTSTRUCT p{};BeginPaint(hwnd,&p);EndPaint(hwnd,&p);}return 0;case WM_ERASEBKGND:return 1;
    case WM_SIZE:if(a.engine){if(w==SIZE_MINIMIZED){if(a.settings.tray)PostMessageW(hwnd,WM_APP+4,0,0);a.updateRenderTimer();}else {a.layout();a.updateRenderTimer();}}return 0;
    case WM_SIZING:if(!a.hidden&&a.renderTimerInterval>0&&(a.page==0||a.breakWindow)&&InterlockedExchange(&a.interactiveResize,1)==0)SetEvent(a.dueEvent);break;
    case WM_EXITSIZEMOVE:if(InterlockedExchange(&a.interactiveResize,0)!=0){SetEvent(a.dueEvent);a.refreshTimerDisplay();}a.updateRenderTimer();return 0;
   case WM_GETMINMAXINFO:{auto size=reinterpret_cast<MINMAXINFO*>(l);RECT frame{0,0,a.px(520),a.minimumTimerClientHeight()};AdjustWindowRectExForDpi(&frame,DWORD(GetWindowLongPtrW(hwnd,GWL_STYLE)),GetMenu(hwnd)!=nullptr,DWORD(GetWindowLongPtrW(hwnd,GWL_EXSTYLE)),a.dpi);size->ptMinTrackSize={frame.right-frame.left,frame.bottom-frame.top};return 0;}
   case WM_DPICHANGED:{a.settingsScroller.rescale(double(HIWORD(w))/a.dpi);a.dpi=HIWORD(w);auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.createFonts();a.layout();return 0;}
   case WM_SETTINGCHANGE:case WM_THEMECHANGED:case WM_SYSCOLORCHANGE:if(a.engine){a.createFonts();a.applyTheme();a.layout();a.layoutBreak();a.updateRenderTimer();if(msg==WM_SETTINGCHANGE)a.timeChanged();}return 0;
   case WM_TIMECHANGE:_tzset();a.timeChanged();return 0;
   case WM_DISPLAYCHANGE:if(a.page==2)a.buildSettings();return 0;
   case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
   case WM_TIMER:if(w==RENDER)a.refreshTimerDisplay();else if(w==CHECKPOINT){a.saveTimer();if(a.dirtySettings)a.saveSettings();}else if(w==SCROLL)a.stepScroll();return 0;
   case UPDATE_RESULT:{std::unique_ptr<UpdateMessage> result(reinterpret_cast<UpdateMessage*>(l));if(result)a.applyUpdateResult(result->result);return 0;}
   case ENGINE_MESSAGE:if(!a.quitting){a.engine->tick();a.schedule();if(a.engine->scheduled()){a.updateAccessibleTimer();a.updateScheduleStatus();if(!a.hidden&&a.page==0)InvalidateRect(hwnd,nullptr,FALSE);}}return 0;
   case WM_APP+3:a.error(L"Eye Break Reminder couldn't load some saved data. Defaults or a fresh timer have been restored.");return 0;
   case WM_APP+4:a.hideMain();return 0;
    case PREVIEW_REFRESH:a.previewRefreshPosted=false;a.refreshPreview();return 0;
    case RESIZE_REFRESH:InterlockedExchange(&a.resizeRefreshPosted,0);if(!a.quitting&&InterlockedCompareExchange(&a.interactiveResize,0,0)!=0)a.refreshTimerDisplay(false);return 0;
   case TRAY_MESSAGE:{UINT event=LOWORD(l);if(event==WM_LBUTTONUP||event==NIN_SELECT||event==NIN_KEYSELECT||event==NIN_BALLOONUSERCLICK)a.showMain();else if(event==WM_CONTEXTMENU||event==WM_RBUTTONUP)a.trayMenu({GET_X_LPARAM(w),GET_Y_LPARAM(w)});return 0;}
   case MM_WOM_DONE:if(a.audio&&a.audio->done(w,l)&&!a.audio->preview&&a.settings.repeat&&a.settings.alarm&&a.engine->snapshot().phase==Phase::Break&&!a.engine->snapshot().held&&!a.locked&&!a.sleeping)a.audio->play(a.settings);return 0;
   case WM_POWERBROADCAST:if(w==PBT_APMSUSPEND){a.sleeping=true;a.suspend(false);}else if(w==PBT_APMRESUMEAUTOMATIC||w==PBT_APMRESUMESUSPEND){a.sleeping=false;a.wake();}return TRUE;
   case WM_WTSSESSION_CHANGE:if(w==WTS_SESSION_LOCK){a.locked=true;a.suspend(true);}else if(w==WTS_SESSION_UNLOCK){a.locked=false;a.wake();}return 0;
   case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);
   case WM_QUERYENDSESSION:if(a.engine){a.saveSettings();a.saveTimer();}return TRUE;
   case WM_CLOSE:a.closeMain();return 0;
   case WM_DESTROY:{a.quitting=true;if(a.updateDispatch){std::lock_guard<std::mutex> lock(a.updateDispatch->mutex);a.updateDispatch->alive=false;a.updateDispatch->target=nullptr;}MSG pending{};while(PeekMessageW(&pending,hwnd,UPDATE_RESULT,UPDATE_RESULT,PM_REMOVE))delete reinterpret_cast<UpdateMessage*>(pending.lParam);KillTimer(hwnd,RENDER);KillTimer(hwnd,CHECKPOINT);KillTimer(hwnd,SCROLL);if(a.stopEvent)SetEvent(a.stopEvent);if(a.worker){WaitForSingleObject(a.worker,3000);CloseHandle(a.worker);a.worker=nullptr;}if(a.trayAdded)Shell_NotifyIconW(NIM_DELETE,&a.trayData);WTSUnRegisterSessionNotification(hwnd);if(a.trayMenuOwner){DestroyWindow(a.trayMenuOwner);a.trayMenuOwner=nullptr;}PostQuitMessage(0);return 0;}
  }return DefWindowProcW(hwnd,msg,w,l);
 }
 int run(HINSTANCE h,int show){instance=h;app=this;InitializeCriticalSection(&deadlineLock);stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);dueEvent=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!stopEvent||!dueEvent)throw std::runtime_error("Timer scheduler unavailable");
  INITCOMMONCONTROLSEX common{sizeof(common),ICC_STANDARD_CLASSES|ICC_LISTVIEW_CLASSES|ICC_UPDOWN_CLASS|ICC_BAR_CLASSES};InitCommonControlsEx(&common);icon=LoadIconW(instance,MAKEINTRESOURCEW(1));
  WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.hInstance=instance;cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);cls.hIcon=cls.hIconSm=icon;cls.style=CS_HREDRAW|CS_VREDRAW;cls.lpfnWndProc=mainProc;cls.lpszClassName=CLASS;RegisterClassExW(&cls);cls.style=0;cls.lpfnWndProc=breakProc;cls.lpszClassName=BREAK_CLASS;RegisterClassExW(&cls);cls.style=CS_HREDRAW|CS_VREDRAW;cls.lpfnWndProc=paneProc;cls.lpszClassName=L"EyeBreakReminder.Settings";RegisterClassExW(&cls);cls.style=0;
  cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=TRAY_MENU_CLASS;RegisterClassExW(&cls);
  trayMenuOwner=CreateWindowExW(WS_EX_TOOLWINDOW,TRAY_MENU_CLASS,L"",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,nullptr);if(!trayMenuOwner)throw std::runtime_error("Tray menu window unavailable");
  main=CreateWindowExW(WS_EX_APPWINDOW|WS_EX_CONTROLPARENT,CLASS,L"Eye Break Reminder",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,820,720,nullptr,nullptr,instance,nullptr);if(!main)throw std::runtime_error("Window unavailable");updateDispatch=std::make_shared<UpdateDispatch>();updateDispatch->target=main;audio=std::make_unique<Audio>(main);audio->changed=[this]{postPreviewRefresh();};load();dpi=GetDpiForWindow(main);
  auto list=monitors();Monitor selected=preferred(settings,main);for(auto&m:list)if(settings.x>=m.work.left&&settings.x<m.work.right&&settings.y>=m.work.top&&settings.y<m.work.bottom)selected=m;RECT work=selected.work;
  int width=std::min(px(settings.width),int(work.right-work.left)),height=std::min(px(settings.height),int(work.bottom-work.top));int x=settings.x==-32000?work.left+(work.right-work.left-width)/2:std::clamp(settings.x,int(work.left),int(work.right-width));int y=settings.y==-32000?work.top+(work.bottom-work.top-height)/2:std::clamp(settings.y,int(work.top),int(work.bottom-height));SetWindowPos(main,nullptr,x,y,width,height,SWP_NOZORDER);
  createControls();applyTheme();addTray();WTSRegisterSessionNotification(main,NOTIFY_FOR_THIS_SESSION);
  engine->changed=[this]{changed();};engine->due=[this](auto cycle,bool alarm){breakDue(cycle,alarm);};engine->breakCompleted=[this](auto cycle,bool alarm){breakCompleted(cycle,alarm);};engine->ended=[this](Record record){if(settings.history){history.push_back(record);if(history.size()>10000)history.erase(history.begin());saveHistory();updateHistory();}};
  worker=CreateThread(nullptr,0,Application::work,this,0,nullptr);if(!worker)throw std::runtime_error("Timer worker unavailable");changed();SetTimer(main,CHECKPOINT,30000,nullptr);ShowWindow(main,show);UpdateWindow(main);updateRenderTimer();SetFocus(nav[0]);
  HWND lastFocus=nullptr;MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(message.message==WM_MOUSEWHEEL&&handleWheel(message))continue;if(message.message==WM_KEYDOWN&&GetKeyState(VK_CONTROL)<0){if(message.wParam=='R'){engine->reset();continue;}if(message.wParam=='B'&&GetKeyState(VK_SHIFT)<0){engine->takeBreak();continue;}if(message.wParam==VK_OEM_COMMA){showMain();switchPage(2);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_RETURN){HWND focus=GetFocus();wchar_t clsName[32]{};GetClassNameW(focus,clsName,32);if(wcscmp(clsName,L"Button")==0){SendMessageW(focus,BM_CLICK,0,0);continue;}
    // Enter in a schedule time field stores (or rejects) the typed time without leaving the field.
    int focusId=GetDlgCtrlID(focus);if(_wcsicmp(clsName,L"Edit")==0&&focusId>=PERIOD_BASE&&focusId<PERIOD_END){command(focusId,EN_KILLFOCUS);SendMessageW(focus,EM_SETSEL,0,-1);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_ESCAPE&&breakWindow){engine->finish(false);continue;}
   HWND dialog=breakWindow&&IsChild(breakWindow,GetFocus())?breakWindow:main;if(!IsDialogMessageW(dialog,&message)){TranslateMessage(&message);DispatchMessageW(&message);}HWND focus=GetFocus();if(focus!=lastFocus){lastFocus=focus;ensureFocused(focus);ensureBreakVisible(focus);}}
  audio->changed=nullptr;audio.reset();clearAccessibleNames();if(accessibility){accessibility->Release();accessibility=nullptr;}if(backgroundBrush)DeleteObject(backgroundBrush);if(surfaceBrush)DeleteObject(surfaceBrush);if(normalFont)DeleteObject(normalFont);
  if(headingFont)DeleteObject(headingFont);
  if(tabFont)DeleteObject(tabFont);
  if(smallFont)DeleteObject(smallFont);
  if(titleFont)DeleteObject(titleFont);
  if(countFont)DeleteObject(countFont);
  CloseHandle(stopEvent);CloseHandle(dueEvent);DeleteCriticalSection(&deadlineLock);return 0;
 }
};
Application*Application::app=nullptr;
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,LPWSTR,int show){
 OSVERSIONINFOEXW version{};version.dwOSVersionInfoSize=sizeof(version);GetVersionExW(reinterpret_cast<OSVERSIONINFOW*>(&version));if(version.dwMajorVersion<10||version.dwBuildNumber<22000){MessageBoxW(nullptr,L"Eye Break Reminder requires Windows 11 x64.",L"Eye Break Reminder",MB_OK|MB_ICONINFORMATION);return 1;}
 SYSTEM_INFO system{};GetNativeSystemInfo(&system);if(system.wProcessorArchitecture!=PROCESSOR_ARCHITECTURE_AMD64){MessageBoxW(nullptr,L"This release supports Windows 11 x64.",L"Eye Break Reminder",MB_OK);return 1;}
#ifdef EYEBREAK_TEST_BUILD
 HANDLE mutex=CreateMutexW(nullptr,FALSE,L"Local\\EyeBreakReminder.GuiAcceptance.Native.1");
#else
 HANDLE mutex=CreateMutexW(nullptr,FALSE,L"Local\\EyeBreakReminder.Native.1");
#endif
 if(!mutex)return 1;
 if(GetLastError()==ERROR_ALREADY_EXISTS){for(int i=0;i<12;++i){HWND existing=FindWindowW(CLASS,nullptr);if(existing){DWORD pid=0;GetWindowThreadProcessId(existing,&pid);AllowSetForegroundWindow(pid);PostMessageW(existing,RegisterWindowMessageW(L"EyeBreakReminder.Activate.Native.1"),0,0);break;}Sleep(100);}CloseHandle(mutex);return 0;}
 HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);ULONG_PTR graphics=0;Gdiplus::GdiplusStartupInput input;if(Gdiplus::GdiplusStartup(&graphics,&input,nullptr)!=Gdiplus::Ok){CloseHandle(mutex);return 1;}
 int result=1;try{Application app;result=app.run(instance,show);}catch(const std::exception&){MessageBoxW(nullptr,L"Eye Break Reminder couldn't start. Please close the app and try again.",L"Eye Break Reminder",MB_OK|MB_ICONERROR);}
 Gdiplus::GdiplusShutdown(graphics);if(SUCCEEDED(com))CoUninitialize();CloseHandle(mutex);return result;
}
