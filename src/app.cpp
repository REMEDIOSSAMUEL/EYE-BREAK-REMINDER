#include "windows_services.hpp"
#include <array>
using namespace eye;
using namespace eye::win;
namespace {
constexpr wchar_t CLASS[]=L"EyeBreakReminder.Native";
constexpr wchar_t BREAK_CLASS[]=L"EyeBreakReminder.Break";
constexpr wchar_t TRAY_MENU_CLASS[]=L"EyeBreakReminder.TrayMenu";
constexpr UINT TRAY_MESSAGE=WM_APP+1, ENGINE_MESSAGE=WM_APP+2, PREVIEW_REFRESH=WM_APP+5;
constexpr int NAV_TIMER=10,NAV_HISTORY=11,NAV_SETTINGS=12,PAUSE=20,RESET=21,TAKE_BREAK=22,COMPLETE=23,SKIP=24,SNOOZE1=25,SNOOZE3=26,SNOOZE5=27;
constexpr int COUNTDOWN=40,TIMER_STATE=41,COUNT_CAPTION=42,BREAK_TITLE=43,BREAK_INSTRUCTION=44,BREAK_GUIDANCE=45,HISTORY_TOGGLE=30,CLEAR_HISTORY=31,ALARM_TOGGLE=32,WORK=100,BREAK_SECONDS=101,SOUND=102,VOLUME=103,MODE=104,MONITOR=105,THEME=106,REPEAT=107,NOTIFY=108,SNOOZE=109,AUTO_START=110,STARTUP=111,TRAY=112,RESTORE=113,PAUSE_LOCK=114,SELECT_MONITOR=115,PREVIEW=116,STOP_AUDIO=117,RESET_SETTINGS=118,VOLUME_VALUE=119;
constexpr UINT_PTR RENDER=1,CHECKPOINT=2,SCROLL=3;
constexpr int SECTION_BASE=130,SECTION_COUNT=5;
// Settings controls are typed so one layout engine can place them on a shared grid.
using Kind=geometry::FormKind;
struct Control {HWND handle{};int id=0;int page=0;Kind kind=Kind::Plain;HWND buddySpin{};int x=0,y=0,w=0,h=0,spinWidth=0,rowHeight=0,section=0;bool sameRow=false,indent=false;};
struct Placement {HWND handle{};int x=0,y=0,w=0,h=0;};
struct Colors {COLORREF background=RGB(247,248,250),surface=RGB(255,255,255),hover=RGB(239,243,249),foreground=RGB(24,30,42),secondary=RGB(93,103,119),line=RGB(215,222,232),accent=RGB(37,99,235);bool dark=false,contrast=false;};
class Application {
public:
 HINSTANCE instance{};HWND main{},breakWindow{},trayMenuOwner{};HICON icon{};HFONT normalFont{},headingFont{},tabFont{},smallFont{},titleFont{},countFont{},breakFont{},breakTitleFont{},breakCountFont{};int countSize=0;HBRUSH backgroundBrush{},surfaceBrush{};
 Settings settings;std::unique_ptr<Engine> engine;std::unique_ptr<Audio> audio;std::vector<Record> history;
 std::vector<Control> controls;std::array<HWND,3> nav{};std::array<HWND,5> sectionNav{};int settingsSection=0,buildSection=0;HWND historyList{},settingsPane{};std::vector<Monitor> displays;
 Colors colors;std::wstring directory;UINT dpi=96;double textScale=1;bool hidden=false,locked=false,sleeping=false,quitting=false,quietBreak=false,loading=false,trayAdded=false,dirtySettings=false,saveWarned=false;
 int page=0,settingsHeight=0,breakHeight=0,settingsApplied=INT_MIN,breakApplied=INT_MIN,historyApplied=0;std::uint64_t notifiedCycle=0,alarmedCycle=0;NOTIFYICONDATAW trayData{};
 ScrollModel settingsScroller,breakScroller,historyScroller{0.05};std::vector<Placement> breakItems;bool scrollTimer=false,previewRefreshPosted=false;double scrollClock=0;
 HANDLE dueEvent{},stopEvent{};HANDLE worker{};UINT activateMessage=RegisterWindowMessageW(L"EyeBreakReminder.Activate.Native.1");UINT quitMessage=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");UINT explorerMessage=RegisterWindowMessageW(L"TaskbarCreated");
 double deadline=0;CRITICAL_SECTION deadlineLock{};RECT normalBounds{};bool haveNormalBounds=false;
 static Application* app;
 int px(double value)const{return geometry::scaled(value,int(dpi));}
 int fontHeight(int points)const{return -int(std::round(points*dpi/72.0*textScale));}
 void error(const wchar_t* message){inform(main,L"Eye Break Reminder",message);}
 LRESULT drawButton(NMHDR* notification){
  if(!notification||notification->code!=NM_CUSTOMDRAW||colors.contrast)return CDRF_DODEFAULT;
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
  COLORREF fill=checkbox?colors.background:(primary?colors.accent:(selected||hot?colors.hover:colors.surface));
  COLORREF ink=enabled?colors.foreground:colors.secondary;if(primary)ink=colors.dark?RGB(15,28,46):RGB(255,255,255);
  if(pressed&&!checkbox)fill=colors.hover;
  if(pressed&&primary)ink=colors.foreground;
  RECT rect=draw->rc;FillRect(draw->hdc,&rect,backgroundBrush);
  auto rgba=[](COLORREF color){return Gdiplus::Color(255,GetRValue(color),GetGValue(color),GetBValue(color));};
  {Gdiplus::Graphics graphics(draw->hdc);graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
   if(checkbox){int side=bpx(18),x=rect.left+bpx(2),y=rect.top+(rect.bottom-rect.top-side)/2;Gdiplus::SolidBrush brush(rgba(selected?colors.accent:colors.surface));Gdiplus::Pen border(rgba(selected?colors.accent:colors.line),float(bpx(1)));graphics.FillRectangle(&brush,x,y,side,side);graphics.DrawRectangle(&border,x,y,side,side);
    if(selected){Gdiplus::Pen tick(rgba(colors.dark?RGB(15,28,46):RGB(255,255,255)),float(bpx(2)));graphics.DrawLine(&tick,x+bpx(4),y+bpx(9),x+bpx(8),y+bpx(13));graphics.DrawLine(&tick,x+bpx(8),y+bpx(13),x+bpx(15),y+bpx(5));}
   }else{float x=float(rect.left+1),y=float(rect.top+1),w=float(rect.right-rect.left-2),h=float(rect.bottom-rect.top-2),corner=float(std::min(bpx(14),int(h)));if(w>0&&h>0){Gdiplus::GraphicsPath path;path.AddArc(x,y,corner,corner,180,90);path.AddArc(x+w-corner,y,corner,corner,270,90);path.AddArc(x+w-corner,y+h-corner,corner,corner,0,90);path.AddArc(x,y+h-corner,corner,corner,90,90);path.CloseFigure();Gdiplus::SolidBrush brush(rgba(fill));Gdiplus::Pen border(rgba(primary||selected?colors.accent:colors.line),float(bpx(1)));graphics.FillPath(&brush,&path);graphics.DrawPath(&border,&path);}}
  }
  wchar_t caption[512]{};GetWindowTextW(button,caption,512);RECT textRect=rect;InflateRect(&textRect,-bpx(12),-bpx(4));if(checkbox)textRect.left=rect.left+bpx(32);
  int saved=SaveDC(draw->hdc);SelectObject(draw->hdc,reinterpret_cast<HFONT>(SendMessageW(button,WM_GETFONT,0,0)));
  UINT flags=checkbox?DT_LEFT|DT_WORDBREAK:DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS;LRESULT cues=SendMessageW(button,WM_QUERYUISTATE,0,0);if(cues&UISF_HIDEACCEL)flags|=DT_HIDEPREFIX;
  if(checkbox){RECT measured=textRect;DrawTextW(draw->hdc,caption,-1,&measured,flags|DT_CALCRECT);int height=measured.bottom-measured.top;textRect.top=rect.top+std::max(0,(int(rect.bottom-rect.top)-height)/2);}
  SetTextColor(draw->hdc,ink);SetBkMode(draw->hdc,TRANSPARENT);DrawTextW(draw->hdc,caption,-1,&textRect,flags);
  if((draw->uItemState&CDIS_FOCUS)&&!(cues&UISF_HIDEFOCUS)){RECT focus=rect;InflateRect(&focus,-bpx(5),-bpx(5));DrawFocusRect(draw->hdc,&focus);}RestoreDC(draw->hdc,saved);
  return CDRF_SKIPDEFAULT;
 }
 bool saveFile(const wchar_t* name,const std::string&content){if(writeAtomic(directory+L"\\"+name,content))return true;if(!saveWarned&&!locked&&!sleeping&&!quitting){saveWarned=true;error(L"Your changes couldn't be saved. Check that your device has free space and try again.");}return false;}
 void saveSettings(){captureBounds();saveFile(L"settings.ini",encodeSettings(settings));dirtySettings=false;}
 void saveTimer(){saveFile(L"timer.dat",encodeTimer(engine->save()));}
 void saveHistory(){saveFile(L"history.dat",encodeHistory(history));}
 void load(){
  directory=dataDirectory();std::string text;bool damaged=false;
  auto path=directory+L"\\settings.ini";if(exists(path)&&(!read(path,text,65536)||!decodeSettings(text,settings))){quarantine(path);settings={};damaged=true;}settings.validate();settings.startup=startupEnabled();
  engine=std::make_unique<Engine>(settings,monotonic,utc);Saved saved;path=directory+L"\\timer.dat";
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
  HIGHCONTRASTW high{};high.cbSize=sizeof(high);SystemParametersInfoW(SPI_GETHIGHCONTRAST,sizeof(high),&high,0);colors.contrast=(high.dwFlags&HCF_HIGHCONTRASTON)!=0;
  DWORD light=1,size=sizeof(light);RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&light,&size);
  colors.dark=settings.theme==2||(settings.theme==0&&!light);
  if(colors.contrast){colors.background=colors.surface=colors.hover=GetSysColor(COLOR_WINDOW);colors.foreground=GetSysColor(COLOR_WINDOWTEXT);colors.secondary=colors.foreground;colors.line=colors.foreground;colors.accent=GetSysColor(COLOR_HIGHLIGHT);}
  else {colors.background=colors.dark?RGB(26,29,35):RGB(247,248,250);colors.surface=colors.dark?RGB(39,44,53):RGB(255,255,255);colors.hover=colors.dark?RGB(51,59,72):RGB(239,243,249);colors.foreground=colors.dark?RGB(239,243,249):RGB(24,30,42);colors.secondary=colors.dark?RGB(169,182,201):RGB(93,103,119);colors.line=colors.dark?RGB(67,76,91):RGB(215,222,232);colors.accent=colors.dark?RGB(96,165,250):RGB(37,99,235);}
  if(backgroundBrush)DeleteObject(backgroundBrush);
  backgroundBrush=CreateSolidBrush(colors.background);
  if(surfaceBrush)DeleteObject(surfaceBrush);
  surfaceBrush=CreateSolidBrush(colors.surface);
  BOOL dark=colors.dark&&!colors.contrast;DwmSetWindowAttribute(main,20,&dark,sizeof(dark));int rounded=2;DwmSetWindowAttribute(main,33,&rounded,sizeof(rounded));int backdrop=colors.contrast?1:2;DwmSetWindowAttribute(main,38,&backdrop,sizeof(backdrop));
  if(breakWindow){DwmSetWindowAttribute(breakWindow,20,&dark,sizeof(dark));DwmSetWindowAttribute(breakWindow,33,&rounded,sizeof(rounded));}
  for(auto&c:controls){themeControl(c.handle);if(c.buddySpin)themeControl(c.buddySpin);InvalidateRect(c.handle,nullptr,TRUE);}
  {bool darkUi=colors.dark&&!colors.contrast;if(settingsPane)SetWindowTheme(settingsPane,darkUi?L"DarkMode_Explorer":nullptr,nullptr);if(historyList)SetWindowTheme(historyList,darkUi?L"DarkMode_Explorer":nullptr,nullptr);}
  for(auto h:nav)if(h)InvalidateRect(h,nullptr,TRUE);
  for(auto h:sectionNav)if(h)InvalidateRect(h,nullptr,TRUE);
  if(historyList){ListView_SetBkColor(historyList,colors.background);ListView_SetTextBkColor(historyList,colors.background);ListView_SetTextColor(historyList,colors.foreground);}
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
    if(selected){RECT bar{rect.left,rect.bottom-bpx(3),rect.right,rect.bottom};HBRUSH accentBrush=CreateSolidBrush(colors.accent);FillRect(draw->hdc,&bar,accentBrush);DeleteObject(accentBrush);}
    ink=selected||hot?colors.foreground:colors.secondary;
   }else{
    // Secondary navigation: shorter, smaller text, quiet inactive segments, a tinted (never solid) selection.
    COLORREF quiet=mix(colors.background,colors.surface,55),quietBorder=mix(colors.background,colors.line,65);
    COLORREF fill=selected?mix(colors.surface,colors.accent,22):(hot||pressed?colors.hover:quiet);ink=selected||hot?colors.foreground:colors.secondary;
    Gdiplus::GraphicsPath path;roundedRect(path,float(rect.left+1),float(rect.top+1),float(rect.right-rect.left-2),float(rect.bottom-rect.top-2),float(bpx(10)));Gdiplus::SolidBrush brush(rgba(fill));Gdiplus::Pen border(rgba(selected?colors.accent:quietBorder),float(bpx(1)));g.FillPath(&brush,&path);g.DrawPath(&border,&path);
   }
  }
  wchar_t caption[64]{};GetWindowTextW(button,caption,64);int saved=SaveDC(draw->hdc);
  SelectObject(draw->hdc,reinterpret_cast<HFONT>(SendMessageW(button,WM_GETFONT,0,0)));
  UINT flags=DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS;LRESULT cues=SendMessageW(button,WM_QUERYUISTATE,0,0);if(cues&UISF_HIDEACCEL)flags|=DT_HIDEPREFIX;
  RECT text=rect;InflateRect(&text,-bpx(tab?8:5),0);if(tab)text.bottom-=bpx(3);
  SetTextColor(draw->hdc,ink);SetBkMode(draw->hdc,TRANSPARENT);DrawTextW(draw->hdc,caption,-1,&text,flags);
  if((draw->uItemState&CDIS_FOCUS)&&!(cues&UISF_HIDEFOCUS)){RECT focus=rect;InflateRect(&focus,-bpx(4),-bpx(4));DrawFocusRect(draw->hdc,&focus);}
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
   if(thumbX>x0){Gdiplus::GraphicsPath filled;roundedRect(filled,x0,y,float(thumbX)-x0,t,t);Gdiplus::SolidBrush accent(rgba(colors.accent));g.FillPath(&accent,&filled);}
   return CDRF_SKIPDEFAULT;}
  if(draw->dwItemSpec==TBCD_THUMB){float d=float(bpx(16)),cx=float((thumb.left+thumb.right)/2),cy=float((thumb.top+thumb.bottom)/2);
   Gdiplus::SolidBrush ring(rgba(colors.background));g.FillEllipse(&ring,cx-d/2-float(bpx(2)),cy-d/2-float(bpx(2)),d+float(bpx(4)),d+float(bpx(4)));
   Gdiplus::SolidBrush accent(rgba(colors.accent));g.FillEllipse(&accent,cx-d/2,cy-d/2,d,d);return CDRF_SKIPDEFAULT;}
  return CDRF_SKIPDEFAULT;
 }
 void themeControl(HWND h){
  wchar_t name[32]{};GetClassNameW(h,name,32);bool dark=colors.dark&&!colors.contrast;
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
   case WM_NCPAINT:{HDC dc=GetWindowDC(h);RECT window{};GetWindowRect(h,&window);OffsetRect(&window,-window.left,-window.top);int border=std::max(1,a.px(1));bool focused=GetFocus()==h;
     FillRect(dc,&window,a.surfaceBrush);HPEN pen=CreatePen(PS_SOLID,border,focused?a.colors.accent:a.colors.line);auto oldPen=SelectObject(dc,pen);auto oldBrush=SelectObject(dc,GetStockObject(NULL_BRUSH));
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
  DWORD style=(kind==Kind::Value?SS_RIGHT:SS_LEFT)|SS_NOPREFIX|(kind==Kind::Caption||kind==Kind::Value?SS_CENTERIMAGE:0); // the value readout is right-aligned so it ends on the column edge
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
 HWND find(int id){for(auto&c:controls)if(c.id==id)return c.handle;return nullptr;}
 void updateVolumeLabel(){HWND v=find(VOLUME_VALUE);if(v)SetWindowTextW(v,(std::to_wstring(settings.volume)+L"%").c_str());}
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
  loading=true;buildSection=0;for(auto it=controls.begin();it!=controls.end();){if(it->page==2){DestroyWindow(it->handle);it=controls.erase(it);}else ++it;}
  // Buddy spin controls are recreated with their edits.
  EnumChildWindows(settingsPane,[](HWND child,LPARAM)->BOOL{wchar_t name[64]{};GetClassNameW(child,name,64);if(wcscmp(name,UPDOWN_CLASSW)==0)DestroyWindow(child);return TRUE;},0);
  label(L"Work and break intervals",Kind::Heading);number(L"Work interval (minutes)",WORK,settings.workMinutes,1,180);number(L"Break duration (seconds)",BREAK_SECONDS,settings.breakSeconds,5,300);
  hint(L"Changes apply to the next cycle. Reset starts a fresh work interval.");
  buildSection=1;label(L"Alarm",Kind::Heading);checkbox(L"Alarm enabled",ALARM_TOGGLE,2,settings.alarm,settingsPane);
  combo(L"Alarm sound",SOUND,{L"Gentle",L"Bell",L"Chime",L"Clear",L"Soft"},settings.sound);
  label(L"Alarm volume",Kind::Caption);HWND volume=control(TRACKBAR_CLASSW,L"",TBS_NOTICKS|TBS_BOTH,VOLUME,2,Kind::Slider,settingsPane);SendMessageW(volume,TBM_SETRANGE,TRUE,MAKELONG(0,100));SendMessageW(volume,TBM_SETPOS,TRUE,settings.volume);SetWindowTextW(volume,L"Alarm volume, percent");
  label((std::to_wstring(settings.volume)+L"%").c_str(),Kind::Value);controls.back().id=VOLUME_VALUE;controls.back().sameRow=true;
  checkbox(L"Repeat until the break ends or is acknowledged",REPEAT,2,settings.repeat,settingsPane);
  control(L"BUTTON",L"Preview alarm",BS_PUSHBUTTON,PREVIEW,2,Kind::Button,settingsPane);control(L"BUTTON",L"Stop preview",BS_PUSHBUTTON,STOP_AUDIO,2,Kind::Button,settingsPane);controls.back().sameRow=true;
  buildSection=2;label(L"Break reminders",Kind::Heading);checkbox(L"Windows notifications",NOTIFY,2,settings.notifications,settingsPane);checkbox(L"Allow snooze (1, 3 or 5 minutes)",SNOOZE,2,settings.snooze,settingsPane);
  label(L"Break window",Kind::Heading);
  combo(L"Break presentation",MODE,{L"Normal window",L"Compact reminder",L"Fullscreen reminder (opt in)"},settings.mode);combo(L"Preferred monitor",MONITOR,{L"Active display",L"Primary display",L"Selected display"},settings.monitor);
  displays=monitors();std::vector<std::wstring> names;int chosen=0;for(std::size_t i=0;i<displays.size();++i){names.push_back(L"Display "+std::to_wstring(i+1)+(displays[i].primary?L" (primary)":L""));if(utf8(displays[i].device)==settings.selectedMonitor)chosen=int(i);}combo(L"Selected display",SELECT_MONITOR,names,chosen);
  buildSection=3;label(L"Appearance",Kind::Heading);combo(L"Theme",THEME,{L"Use system setting",L"Light",L"Dark"},settings.theme);
  label(L"Behaviour",Kind::Heading);checkbox(L"Start timer automatically on launch",AUTO_START,2,settings.autoStart,settingsPane);checkbox(L"Start with Windows",STARTUP,2,settings.startup,settingsPane);
  hint(L"Open Eye Break Reminder automatically when you sign in.",true);checkbox(L"Minimize to system tray",TRAY,2,settings.tray,settingsPane);hint(L"Closing keeps reminders active. Choose Exit in the tray menu to quit.",true);
  checkbox(L"Resume countdown when reopening the app",RESTORE,2,settings.restore,settingsPane);hint(L"Reinstalling after uninstall starts a fresh work interval. Preferences and history are kept.",true);checkbox(L"Pause while workstation is locked",PAUSE_LOCK,2,settings.pauseLocked,settingsPane);
  hint(L"Sleep counts as elapsed work time. Wake shows at most one reminder. Paused timers stay paused.",true);
  buildSection=4;label(L"About",Kind::Heading);label(L"Eye Break Reminder");hint(L"Version 1.0.6 · x64 · Windows 11");
  hint(L"All data stays on this device. No internet, telemetry, account, camera or microphone.");
  label(L"Accessibility",Kind::Heading);hint(L"Uses Windows text scaling, high contrast and keyboard focus.");
  hint(L"Ctrl+R: Reset · Ctrl+Shift+B: Take break · Ctrl+comma: Settings");
  control(L"BUTTON",L"Reset all settings",BS_PUSHBUTTON,RESET_SETTINGS,2,Kind::Button,settingsPane);loading=false;refreshPreview();layout();
 }
#pragma GCC diagnostic pop
 void createControls(){
  dpi=GetDpiForWindow(main);createFonts();
  for(int i=0;i<3;++i){nav[i]=CreateWindowExW(0,L"BUTTON",i==0?L"&Timer":i==1?L"&History":L"&Settings",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTORADIOBUTTON|BS_PUSHLIKE|(i==0?WS_GROUP:0),0,0,0,0,main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(NAV_TIMER+i)),instance,nullptr);SendMessageW(nav[i],WM_SETFONT,reinterpret_cast<WPARAM>(tabFont),TRUE);}
  control(L"STATIC",L"Running",SS_CENTER|SS_CENTERIMAGE,TIMER_STATE,0);control(L"STATIC",L"Next eye break",SS_CENTER|SS_CENTERIMAGE,COUNT_CAPTION,0);control(L"STATIC",L"20:00",SS_CENTER|SS_CENTERIMAGE,COUNTDOWN,0);
  control(L"BUTTON",L"Take a break now",BS_DEFPUSHBUTTON,TAKE_BREAK,0);control(L"BUTTON",L"Pause",BS_PUSHBUTTON,PAUSE,0);control(L"BUTTON",L"Reset",BS_PUSHBUTTON,RESET,0);
  historyList=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"Eye break history",WS_CHILD|WS_TABSTOP|LVS_REPORT|LVS_SINGLESEL|LVS_SHOWSELALWAYS,0,0,1,1,main,reinterpret_cast<HMENU>(200),instance,nullptr);ListView_SetExtendedListViewStyle(historyList,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER);
  for(int i=0;i<3;++i){LVCOLUMNW col{};col.mask=LVCF_TEXT|LVCF_WIDTH|LVCF_SUBITEM;col.pszText=const_cast<LPWSTR>(i==0?L"Date":i==1?L"Break":L"Seconds");col.cx=px(i==0?240:140);col.iSubItem=i;ListView_InsertColumn(historyList,i,&col);}
  checkbox(L"Save history on this device",HISTORY_TOGGLE,1,settings.history,main);control(L"BUTTON",L"Clear history",BS_PUSHBUTTON,CLEAR_HISTORY,1);
  {const wchar_t*names[SECTION_COUNT]={L"Intervals",L"Alarm",L"Reminders",L"General",L"About"};
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
  ShowWindow(settingsPane,page==2?SW_SHOW:SW_HIDE);ShowWindow(historyList,page==1?SW_SHOW:SW_HIDE);if(page==1)updateHistory();layout();updateRenderTimer();InvalidateRect(main,nullptr,TRUE);}
 void layout(){
  if(!main||!settingsPane)return;
  std::vector<Placement> moves;auto move=[&](HWND window,int x,int y,int w,int h){if(window)moves.push_back({window,x,y,w,h});};
  RECT client{};GetClientRect(main,&client);int w=client.right,h=client.bottom,pad=px(28),gap=px(12),bh=px(std::max(36.0,30.0*textScale));
  Column col=column(w);int tabTop=px(16),tabHeightNow=tabHeight();
  {std::vector<int> natural;for(int i=0;i<3;++i){std::wstring text=windowText(nav[i]);text.erase(std::remove(text.begin(),text.end(),L'&'),text.end());natural.push_back(measureWidth(nav[i],text)+px(40));}
   for(auto&segment:geometry::segmentRows(natural,col.x,col.width,0,px(60),false))move(nav[segment.index],segment.x,tabTop,segment.width,tabHeightNow);}
  int top=navBottom()+px(28);
  if(page==0){int y=std::max(top+px(285),h-px(150)-2*bh-gap);int buttonWidth=std::min(w-2*pad,px(280*std::sqrt(textScale)));move(find(TAKE_BREAK),(w-buttonWidth)/2,y,buttonWidth,bh);int secondWidth=(buttonWidth-gap)/2;move(find(PAUSE),(w-buttonWidth)/2,y+bh+gap,secondWidth,bh);move(find(RESET),(w-buttonWidth)/2+secondWidth+gap,y+bh+gap,secondWidth,bh);
   int timerTop=navBottom()+px(22),stateBottom=timerTop+px(88);
   int diameter=std::min({px(272),w-px(100),std::max(px(160),y-stateBottom-px(18))});int left=(w-diameter)/2,ty=stateBottom+px(8);
   move(find(TIMER_STATE),pad,timerTop+px(50),w-2*pad,px(38));
   move(find(COUNTDOWN),left,ty+diameter/3,diameter,diameter/3);
   move(find(COUNT_CAPTION),left,ty+diameter*2/3,diameter,px(40));
   int size=std::min(px(56*std::sqrt(textScale)),diameter/4);if(size!=countSize){HFONT previous=countFont;countSize=size;countFont=CreateFontW(-size,0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");SendMessageW(find(COUNTDOWN),WM_SETFONT,reinterpret_cast<WPARAM>(countFont),TRUE);if(previous)DeleteObject(previous);}
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
   f.textHeight=[this,handle=item->handle,text](int width){return measureHeight(handle,text,width);};f.sameRow=item->sameRow;f.indent=item->indent;f.spin=item->buddySpin!=nullptr;form.push_back(std::move(f));}
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
 void paint(HWND hwnd,bool isBreak){
  PAINTSTRUCT ps{};HDC target=BeginPaint(hwnd,&ps);RECT r{};GetClientRect(hwnd,&r);HDC dc=CreateCompatibleDC(target);HBITMAP bitmap=CreateCompatibleBitmap(target,std::max(1L,r.right),std::max(1L,r.bottom));auto previous=SelectObject(dc,bitmap);FillRect(dc,&r,backgroundBrush);auto snap=engine->snapshot();
  if(!isBreak){Column col=column(r.right);int rule=std::max(1,px(1));RECT line{col.x,navBottom()-rule,col.x+col.width,navBottom()};HBRUSH lineBrush=CreateSolidBrush(colors.line);FillRect(dc,&line,lineBrush);DeleteObject(lineBrush);}
  if(isBreak){ // Native STATIC controls render all break content.
  }else if(page==0){
   int top=navBottom()+px(22);Column col=column(r.right);RECT title{col.x,top,col.x+col.width,top+px(44)};text(dc,L"Timer",title,titleFont,colors.foreground);
   std::wstring state=snap.paused?L"Paused":snap.phase==Phase::Break?L"Rest your eyes":snap.phase==Phase::Snooze?L"Snoozed — next reminder below":L"Running";RECT status{px(28),top+px(50),r.right-px(28),top+px(88)};text(dc,state,status,normalFont,colors.secondary,DT_CENTER|DT_SINGLELINE);
   RECT button{};GetWindowRect(find(TAKE_BREAK),&button);MapWindowPoints(nullptr,main,reinterpret_cast<POINT*>(&button),2);int diameter=std::min({px(272),int(r.right)-px(100),std::max(px(160),int(button.top-status.bottom)-px(18))});int left=(r.right-diameter)/2,ty=status.bottom+px(8);
   Gdiplus::Graphics graphics(dc);graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);Gdiplus::Pen track(Gdiplus::Color(255,GetRValue(colors.line),GetGValue(colors.line),GetBValue(colors.line)),float(px(4)));Gdiplus::Pen accent(Gdiplus::Color(255,GetRValue(colors.accent),GetGValue(colors.accent),GetBValue(colors.accent)),float(px(4)));
   graphics.DrawEllipse(&track,left+px(4),ty+px(4),diameter-px(8),diameter-px(8));if(snap.progress()>0)graphics.DrawArc(&accent,left+px(4),ty+px(4),diameter-px(8),diameter-px(8),-90.f,float(360*snap.progress()));
   HFONT large=CreateFontW(-std::min(px(56),diameter/4),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");RECT time{left,ty+diameter/3,left+diameter,ty+diameter*2/3};text(dc,timeText(snap.remaining),time,large,colors.foreground,DT_CENTER|DT_SINGLELINE|DT_VCENTER);DeleteObject(large);
   RECT caption{left,ty+diameter*2/3,left+diameter,ty+diameter*2/3+px(40)};text(dc,snap.phase==Phase::Break?L"Eye break":L"Next eye break",caption,normalFont,colors.secondary,DT_CENTER|DT_SINGLELINE);
   RECT reset{};GetWindowRect(find(RESET),&reset);MapWindowPoints(nullptr,main,reinterpret_cast<POINT*>(&reset),2);RECT rule{px(28),reset.bottom+px(18),r.right-px(28),r.bottom-px(10)};
   std::wstring explanation=L"20 min · Work      20 ft · Look away      20 sec · Rest\nEvery 20 minutes, look around 20 feet / 6 metres away for at least 20 seconds.";
   if(settings.workMinutes!=20||settings.breakSeconds!=20)explanation+=L"\nYour schedule: "+std::to_wstring(settings.workMinutes)+L" min work, "+std::to_wstring(settings.breakSeconds)+L" sec rest.";
   text(dc,explanation,rule,normalFont,colors.secondary,DT_CENTER|DT_WORDBREAK);
  }else if(page==1){int top=navBottom()+px(28);Column col=column(r.right);RECT title{col.x,top,col.x+col.width,top+px(42)};text(dc,L"History",title,titleFont,colors.foreground);
   std::time_t stamp=std::time_t(utc());std::tm tm{};localtime_s(&tm,&stamp);int today=calendarDay(stamp);auto stats=statistics(history,today,today-(tm.tm_wday+6)%7,calendarDay);
   std::wstring summary=history.empty()?L"No breaks recorded yet.\nCompleted eye breaks will appear here.":L"Today: "+std::to_wstring(stats.todayCompleted)+L" completed · "+std::to_wstring(stats.todaySkipped)+L" skipped · "+std::to_wstring(int(std::round(stats.completion)))+L"% completed\nThis week: "+std::to_wstring(stats.weekCompleted)+L" completed · "+std::to_wstring(stats.streak)+L" day streak\nTotal retained: "+std::to_wstring(stats.totalCompleted)+L" completed";
   RECT area{col.x,title.bottom+px(8),col.x+col.width,title.bottom+px(100)*int(std::ceil(textScale))};text(dc,summary,area,normalFont,colors.secondary);
  }
  BitBlt(target,0,0,r.right,r.bottom,dc,0,0,SRCCOPY);SelectObject(dc,previous);DeleteObject(bitmap);DeleteDC(dc);EndPaint(hwnd,&ps);
 }
 void updateAccessibleTimer(){auto snap=engine->snapshot();auto set=[&](int id,const std::wstring&value){HWND h=find(id);if(!h)return;wchar_t old[160]{};GetWindowTextW(h,old,160);if(value!=old)SetWindowTextW(h,value.c_str());};set(COUNTDOWN,timeText(snap.remaining));set(COUNT_CAPTION,snap.phase==Phase::Break?L"Eye break":L"Next eye break");set(TIMER_STATE,snap.paused?L"Paused":snap.phase==Phase::Break?L"Rest your eyes":snap.phase==Phase::Snooze?L"Snoozed — next reminder below":L"Running");}
 void updateHistory(){if(!historyList)return;ListView_DeleteAllItems(historyList);historyScroller.jump(0);historyApplied=0;int row=0;for(auto it=history.rbegin();it!=history.rend()&&row<100;++it,++row){auto date=formatDate(it->at);LVITEMW item{};item.mask=LVIF_TEXT;item.iItem=row;item.pszText=date.data();ListView_InsertItem(historyList,&item);ListView_SetItemText(historyList,row,1,const_cast<LPWSTR>(it->completed?L"Completed":L"Skipped"));auto seconds=std::to_wstring(int(std::round(it->seconds)));ListView_SetItemText(historyList,row,2,seconds.data());}InvalidateRect(main,nullptr,TRUE);}
 void addTray(){trayData={};trayData.cbSize=sizeof(trayData);trayData.hWnd=main;trayData.uID=1;trayData.uFlags=NIF_ICON|NIF_MESSAGE|NIF_TIP|NIF_SHOWTIP;trayData.uCallbackMessage=TRAY_MESSAGE;trayData.hIcon=icon;wcscpy_s(trayData.szTip,L"Eye Break Reminder");trayAdded=Shell_NotifyIconW(NIM_ADD,&trayData)!=0;if(trayAdded){trayData.uVersion=NOTIFYICON_VERSION_4;Shell_NotifyIconW(NIM_SETVERSION,&trayData);}}
 void updateTray(){auto s=engine->snapshot();auto status=s.paused?L"Paused":s.phase==Phase::Break?L"Rest your eyes":s.phase==Phase::Snooze?L"Snoozed":L"Running";auto tip=L"Eye Break Reminder — "+std::wstring(status);wcsncpy_s(trayData.szTip,tip.c_str(),_TRUNCATE);trayData.uFlags=NIF_TIP|NIF_SHOWTIP;if(trayAdded)Shell_NotifyIconW(NIM_MODIFY,&trayData);}
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
 void settingsChanged(){settings.validate();engine->configure(settings);dirtySettings=true;applyTheme();updateTray();InvalidateRect(main,nullptr,TRUE);}
 int selected(int id){return int(SendMessageW(find(id),CB_GETCURSEL,0,0));}
 bool checked(int id){return SendMessageW(find(id),BM_GETCHECK,0,0)==BST_CHECKED;}
 int integer(int id,int previous){wchar_t text[32]{};GetWindowTextW(find(id),text,32);if(!*text)return previous;wchar_t*end=nullptr;long value=wcstol(text,&end,10);return *end?previous:int(std::clamp(value,0L,10000L));}
 void command(int id,int code){
  if(loading)return;
  if(code==EN_SETFOCUS||code==CBN_SETFOCUS||code==BN_SETFOCUS)ensureFocused(find(id));
  if(id>=NAV_TIMER&&id<=NAV_SETTINGS&&code==BN_CLICKED){switchPage(id-NAV_TIMER);return;}
  if(id>=SECTION_BASE&&id<SECTION_BASE+SECTION_COUNT&&code==BN_CLICKED){selectSection(id-SECTION_BASE);return;}
  if(code==BN_CLICKED){switch(id){case PAUSE:togglePause();return;case RESET:engine->reset();return;case TAKE_BREAK:engine->takeBreak();return;case COMPLETE:engine->finish(true);return;case SKIP:engine->finish(false);return;case SNOOZE1:engine->snooze(1);return;case SNOOZE3:engine->snooze(3);return;case SNOOZE5:engine->snooze(5);return;
   case CLEAR_HISTORY:if(confirm(main,L"Clear all history?",L"This removes every eye break recorded on this device.")){history.clear();saveHistory();updateHistory();}return;
   case PREVIEW:if(!audio->play(settings,true))error(L"The alarm couldn't play. Check your Windows audio output.");return;
   case STOP_AUDIO:audio->stop();return;
   case RESET_SETTINGS:if(confirm(main,L"Reset all settings?",L"Restores defaults and disables Start with Windows. Your history is preserved.")){if(!setStartup(false)){error(L"Startup registration couldn't be removed.");return;}settings={};settingsChanged();engine->reset();saveSettings();buildSettings();}return;
   case HISTORY_TOGGLE:settings.history=checked(id);break;case ALARM_TOGGLE:settings.alarm=checked(id);if(!settings.alarm)audio->stop();break;case REPEAT:settings.repeat=checked(id);break;case NOTIFY:settings.notifications=checked(id);if(!settings.notifications)clearNotification();break;case SNOOZE:settings.snooze=checked(id);break;case AUTO_START:settings.autoStart=checked(id);break;case TRAY:settings.tray=checked(id);break;case RESTORE:settings.restore=checked(id);break;case PAUSE_LOCK:settings.pauseLocked=checked(id);break;
   case STARTUP:{bool requested=checked(id);if(!setStartup(requested)){SendMessageW(find(id),BM_SETCHECK,settings.startup?BST_CHECKED:BST_UNCHECKED,0);error(L"Startup couldn't be changed. Your organisation may manage startup apps.");return;}settings.startup=requested;break;}default:return;}}
  else if(code==CBN_SELCHANGE){switch(id){case SOUND:settings.sound=selected(id);break;case MODE:settings.mode=selected(id);break;case MONITOR:settings.monitor=selected(id);break;case THEME:settings.theme=selected(id);break;case SELECT_MONITOR:{int index=selected(id);if(index>=0&&index<int(displays.size()))settings.selectedMonitor=utf8(displays[index].device);break;}default:return;}}
  else if(code==EN_KILLFOCUS&&(id==WORK||id==BREAK_SECONDS)){if(id==WORK)settings.workMinutes=integer(id,settings.workMinutes);else settings.breakSeconds=integer(id,settings.breakSeconds);settings.validate();SetWindowTextW(find(id),std::to_wstring(id==WORK?settings.workMinutes:settings.breakSeconds).c_str());}
  else return;
  settingsChanged();saveSettings();
 }
 void captureBounds(){if(!main||IsIconic(main)||IsZoomed(main)||hidden)return;RECT r{};GetWindowRect(main,&r);settings.x=r.left;settings.y=r.top;settings.width=int((r.right-r.left)*96/dpi);settings.height=int((r.bottom-r.top)*96/dpi);settings.validate();normalBounds=r;haveNormalBounds=true;}
 void showMain(bool focusBreak=true){hidden=false;ShowWindow(main,IsIconic(main)?SW_RESTORE:SW_SHOW);SetForegroundWindow(main);updateRenderTimer();if(focusBreak&&engine->snapshot().phase==Phase::Break){if(!breakWindow)showBreak();else SetForegroundWindow(breakWindow);}}
 void hideMain(){if(!trayAdded){error(L"The tray icon isn't available. The window will stay open so you can control the timer.");ShowWindow(main,SW_RESTORE);return;}captureBounds();hidden=true;ShowWindow(main,SW_HIDE);saveSettings();saveTimer();updateRenderTimer();}
 void closeMain(){if(!settings.tray){exit();return;}if(!settings.trayExplained){settings.trayExplained=true;saveSettings();inform(main,L"The timer keeps running in the system tray",L"Closing keeps your reminders active. To quit, right-click the tray icon and choose Exit. You can change this in Settings.");}hideMain();}
 void updateRenderTimer(){if(!main)return;KillTimer(main,RENDER);if(engine&&engine->snapshot().paused)return;if((!hidden&&!IsIconic(main)&&page==0)||breakWindow){BOOL animations=TRUE;SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&animations,0);SetTimer(main,RENDER,animations?250:1000,nullptr);}}
 void schedule(){auto s=engine->snapshot();EnterCriticalSection(&deadlineLock);deadline=s.paused||engine->isSuspended()?0:monotonic()+s.remaining;LeaveCriticalSection(&deadlineLock);SetEvent(dueEvent);}
 static DWORD WINAPI work(LPVOID context){auto self=static_cast<Application*>(context);HANDLE events[]={self->stopEvent,self->dueEvent};for(;;){EnterCriticalSection(&self->deadlineLock);double when=self->deadline;LeaveCriticalSection(&self->deadlineLock);DWORD timeout=when<=0?INFINITE:DWORD(std::clamp(std::ceil((when-monotonic())*1000),1.0,double(MAXDWORD-1)));DWORD result=WaitForMultipleObjects(2,events,FALSE,timeout);if(result==WAIT_OBJECT_0||result==WAIT_FAILED)return 0;if(result==WAIT_TIMEOUT){EnterCriticalSection(&self->deadlineLock);if(self->deadline==when)self->deadline=0;LeaveCriticalSection(&self->deadlineLock);PostMessageW(self->main,ENGINE_MESSAGE,0,0);}}}
 void changed(){updateAccessibleTimer();if(engine->snapshot().phase!=Phase::Break)dismissBreak();SetWindowTextW(find(PAUSE),engine->snapshot().paused?L"Resume":L"Pause");schedule();saveTimer();updateTray();updateRenderTimer();InvalidateRect(main,nullptr,TRUE);if(breakWindow){SetWindowTextW(GetDlgItem(breakWindow,BREAK_GUIDANCE),engine->snapshot().paused?L"Break paused. Resume from the main window.":L"Keep looking into the distance.");InvalidateRect(breakWindow,nullptr,TRUE);}}
 void breakDue(std::uint64_t cycle,bool alarm){if(locked||sleeping||engine->isSuspended())return;if(alarm&&!audio->play(settings))error(L"The alarm couldn't play. Check your Windows audio output.");if(hidden||IsIconic(main))notify(cycle);showBreak();}
 // The completion alarm reuses the selected sound, volume and mute setting. It is asynchronous (waveOut) and keyed to the
 // finished break, so repeated timer messages, repaints, window restores and recovery cannot play it twice.
 void breakCompleted(std::uint64_t cycle,bool alarm){if(!alarm||locked||sleeping||engine->isSuspended()||alarmedCycle==cycle)return;alarmedCycle=cycle;if(!audio->play(settings))error(L"The alarm couldn't play. Check your Windows audio output.");}
 void dismissBreak(){audio->stop();clearNotification();if(breakWindow){quietBreak=true;HWND old=breakWindow;breakWindow=nullptr;DestroyWindow(old);breakItems.clear();quietBreak=false;if(breakFont){DeleteObject(breakFont);breakFont=nullptr;}if(breakTitleFont){DeleteObject(breakTitleFont);breakTitleFont=nullptr;}if(breakCountFont){DeleteObject(breakCountFont);breakCountFont=nullptr;}}updateRenderTimer();}
 void showBreak(){
  if(breakWindow||engine->snapshot().phase!=Phase::Break||locked||sleeping||engine->isSuspended())return;
  auto monitor=preferred(settings,GetForegroundWindow());RECT work=monitor.work;UINT monitorDpi=dpi;
  // Place first, then read the window's actual per-monitor DPI before sizing it.
  DWORD style=settings.mode==2?WS_POPUP|WS_CLIPCHILDREN:WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX|WS_CLIPCHILDREN;
  breakWindow=CreateWindowExW(WS_EX_APPWINDOW,BREAK_CLASS,L"Rest your eyes — Eye Break Reminder",style|WS_VSCROLL,work.left,work.top,100,100,nullptr,nullptr,instance,nullptr);
  if(!breakWindow){error(L"The break reminder couldn't open. Please rest your eyes for 20 seconds.");return;}
  monitorDpi=GetDpiForWindow(breakWindow);breakScroller=ScrollModel();breakApplied=INT_MIN;breakItems.clear();
  auto makeFont=[&](double height,int weight){return CreateFontW(-int(height*monitorDpi/96),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");};
  breakFont=makeFont(14*textScale,FW_NORMAL);breakTitleFont=makeFont(25*textScale,FW_SEMIBOLD);breakCountFont=makeFont(56*std::sqrt(textScale),FW_SEMIBOLD);
  int w=int((settings.mode==1?440:580)*monitorDpi/96),h=int((settings.mode==1?500:580)*monitorDpi/96);
  if(settings.mode==2){work=monitor.bounds;w=work.right-work.left;h=work.bottom-work.top;}else {w=std::min(w,int(work.right-work.left));h=std::min(h,int(work.bottom-work.top));}
  SetWindowPos(breakWindow,nullptr,work.left+(work.right-work.left-w)/2,work.top+(work.bottom-work.top-h)/2,w,h,SWP_NOZORDER);
  SendMessageW(breakWindow,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(icon));SendMessageW(breakWindow,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(icon));
  auto button=[&](const wchar_t* name,int id){HWND child=CreateWindowExW(0,L"BUTTON",name,WS_CHILD|WS_VISIBLE|WS_TABSTOP|(id==COMPLETE?BS_DEFPUSHBUTTON:BS_PUSHBUTTON)|BS_MULTILINE,0,0,0,0,breakWindow,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(breakFont),TRUE);return child;};button(L"I'm back",COMPLETE);button(L"Skip",SKIP);if(settings.snooze){button(L"Snooze 1 min",SNOOZE1);button(L"3 min",SNOOZE3);button(L"5 min",SNOOZE5);}
  auto caption=[&](const wchar_t*name,int id,HFONT font){HWND child=CreateWindowExW(0,L"STATIC",name,WS_CHILD|WS_VISIBLE|SS_CENTER|(id==COUNTDOWN?SS_CENTERIMAGE:0),0,0,1,1,breakWindow,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);};
  caption(L"Rest your eyes",BREAK_TITLE,breakTitleFont);caption(L"Look at something at least 20 feet / 6 metres away.",BREAK_INSTRUCTION,breakFont);caption(timeText(engine->snapshot().remaining).c_str(),COUNTDOWN,breakCountFont);caption(L"Keep looking into the distance.",BREAK_GUIDANCE,breakFont);
  layoutBreak();applyTheme();ShowWindow(breakWindow,SW_SHOW);SetForegroundWindow(breakWindow);FLASHWINFO flash{sizeof(flash),breakWindow,FLASHW_TRAY,3,0};FlashWindowEx(&flash);SetFocus(GetDlgItem(breakWindow,COMPLETE));updateRenderTimer();
 }
 void layoutBreak(){
  if(!breakWindow)return;
  RECT r{};GetClientRect(breakWindow,&r);int scale=int(GetDpiForWindow(breakWindow));auto bpx=[&](double n){return int(n*scale/96.0);};
  int pad=bpx(28),gap=bpx(12),bh=bpx(40*textScale),width=std::min(bpx(380),int(r.right)-2*pad),x=(r.right-width)/2,y=pad;
  breakItems.clear();
  auto place=[&](int id,int height){breakItems.push_back({GetDlgItem(breakWindow,id),x,y,width,height});y+=height+gap;};
  place(BREAK_TITLE,bpx(42*textScale));place(BREAK_INSTRUCTION,bpx(48*textScale));place(COUNTDOWN,bpx(96*std::sqrt(textScale)));place(BREAK_GUIDANCE,bpx(48*textScale));place(COMPLETE,bh);
  int skipWidth=settings.snooze?width/4:width;breakItems.push_back({GetDlgItem(breakWindow,SKIP),x,y,skipWidth-4,bh});
  if(settings.snooze){int widths[3]={width/3,width/5,width-width/4-width/3-width/5};int left=x+width/4;int ids[3]={SNOOZE1,SNOOZE3,SNOOZE5};for(int i=0;i<3;++i){breakItems.push_back({GetDlgItem(breakWindow,ids[i]),left,y,widths[i]-4,bh});left+=widths[i];}}
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
 LRESULT color(HDC dc,HWND child=nullptr,bool input=false){SetBkColor(dc,input?colors.surface:colors.background);COLORREF ink=colors.foreground;if(child&&!colors.contrast){if(reinterpret_cast<HFONT>(SendMessageW(child,WM_GETFONT,0,0))==headingFont)ink=colors.accent;else if(GetWindowLongPtrW(child,GWLP_USERDATA)==1)ink=colors.secondary;}SetTextColor(dc,ink);return reinterpret_cast<LRESULT>(input?surfaceBrush:backgroundBrush);}
 static LRESULT CALLBACK paneProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;case WM_HSCROLL:if(reinterpret_cast<HWND>(l)==a.find(VOLUME)){a.settings.volume=int(SendMessageW(a.find(VOLUME),TBM_GETPOS,0,0));a.updateVolumeLabel();a.settingsChanged();if(LOWORD(w)==TB_ENDTRACK)a.saveSettings();}return 0;case WM_VSCROLL:if(a.barScroll(a.settingsScroller,hwnd,LOWORD(w),a.px(40)))a.settingsMoved();return 0;case WM_MOUSEWHEEL:a.wheelSettings(GET_WHEEL_DELTA_WPARAM(w));return 0;case WM_ERASEBKGND:{RECT r{};GetClientRect(hwnd,&r);FillRect(reinterpret_cast<HDC>(w),&r,a.backgroundBrush);return 1;}case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:case WM_CTLCOLORLISTBOX:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK breakProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:a.paint(hwnd,true);return 0;case WM_ERASEBKGND:return 1;case WM_SIZE:a.layoutBreak();return 0;case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
  case WM_VSCROLL:if(a.barScroll(a.breakScroller,hwnd,LOWORD(w),MulDiv(40,int(GetDpiForWindow(hwnd)),96)))a.breakMoved();return 0;
  case WM_MOUSEWHEEL:a.wheelBreak(GET_WHEEL_DELTA_WPARAM(w));return 0;
  case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CLOSE:if(!a.quietBreak){a.engine->finish(false);return 0;}break;case WM_DPICHANGED:{a.breakScroller.rescale(double(HIWORD(w))/GetDpiForWindow(hwnd));auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.layoutBreak();return 0;}}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK mainProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;
  if(msg==a.activateMessage){a.showMain();return 0;}if(msg==a.quitMessage){a.exit();return 0;}if(msg==a.explorerMessage){a.addTray();a.updateTray();return 0;}
  switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:if(a.engine)a.paint(hwnd,false);else {PAINTSTRUCT p{};BeginPaint(hwnd,&p);EndPaint(hwnd,&p);}return 0;case WM_ERASEBKGND:return 1;
   case WM_SIZE:if(a.engine){if(w==SIZE_MINIMIZED){if(a.settings.tray)PostMessageW(hwnd,WM_APP+4,0,0);a.updateRenderTimer();}else {a.layout();a.updateRenderTimer();}}return 0;
   case WM_GETMINMAXINFO:{auto size=reinterpret_cast<MINMAXINFO*>(l);size->ptMinTrackSize={a.px(520),a.px(480)};return 0;}
   case WM_DPICHANGED:{a.settingsScroller.rescale(double(HIWORD(w))/a.dpi);a.dpi=HIWORD(w);auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.createFonts();a.layout();return 0;}
   case WM_SETTINGCHANGE:case WM_THEMECHANGED:if(a.engine){a.createFonts();a.applyTheme();a.layout();a.layoutBreak();a.updateRenderTimer();}return 0;
   case WM_DISPLAYCHANGE:if(a.page==2)a.buildSettings();return 0;
   case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
   case WM_TIMER:if(w==RENDER){a.engine->tick();a.updateAccessibleTimer();if(!a.hidden&&a.page==0)InvalidateRect(hwnd,nullptr,FALSE);if(a.breakWindow){auto time=timeText(a.engine->snapshot().remaining);wchar_t previous[32]{};GetWindowTextW(GetDlgItem(a.breakWindow,COUNTDOWN),previous,32);if(time!=previous)SetWindowTextW(GetDlgItem(a.breakWindow,COUNTDOWN),time.c_str());InvalidateRect(a.breakWindow,nullptr,FALSE);}}else if(w==CHECKPOINT){a.saveTimer();if(a.dirtySettings)a.saveSettings();}else if(w==SCROLL)a.stepScroll();return 0;
   case ENGINE_MESSAGE:if(!a.quitting){a.engine->tick();a.schedule();}return 0;
   case WM_APP+3:a.error(L"Eye Break Reminder couldn't load some saved data. Defaults or a fresh timer have been restored.");return 0;
   case WM_APP+4:a.hideMain();return 0;
   case PREVIEW_REFRESH:a.previewRefreshPosted=false;a.refreshPreview();return 0;
   case TRAY_MESSAGE:{UINT event=LOWORD(l);if(event==WM_LBUTTONUP||event==NIN_SELECT||event==NIN_KEYSELECT||event==NIN_BALLOONUSERCLICK)a.showMain();else if(event==WM_CONTEXTMENU||event==WM_RBUTTONUP)a.trayMenu({GET_X_LPARAM(w),GET_Y_LPARAM(w)});return 0;}
   case MM_WOM_DONE:if(a.audio&&a.audio->done(w,l)&&!a.audio->preview&&a.settings.repeat&&a.settings.alarm&&a.engine->snapshot().phase==Phase::Break&&!a.locked&&!a.sleeping)a.audio->play(a.settings);return 0;
   case WM_POWERBROADCAST:if(w==PBT_APMSUSPEND){a.sleeping=true;a.suspend(false);}else if(w==PBT_APMRESUMEAUTOMATIC||w==PBT_APMRESUMESUSPEND){a.sleeping=false;a.wake();}return TRUE;
   case WM_WTSSESSION_CHANGE:if(w==WTS_SESSION_LOCK){a.locked=true;a.suspend(true);}else if(w==WTS_SESSION_UNLOCK){a.locked=false;a.wake();}return 0;
   case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);
   case WM_QUERYENDSESSION:if(a.engine){a.saveSettings();a.saveTimer();}return TRUE;
   case WM_CLOSE:a.closeMain();return 0;
   case WM_DESTROY:a.quitting=true;KillTimer(hwnd,RENDER);KillTimer(hwnd,CHECKPOINT);KillTimer(hwnd,SCROLL);if(a.stopEvent)SetEvent(a.stopEvent);if(a.worker){WaitForSingleObject(a.worker,3000);CloseHandle(a.worker);a.worker=nullptr;}if(a.trayAdded)Shell_NotifyIconW(NIM_DELETE,&a.trayData);WTSUnRegisterSessionNotification(hwnd);if(a.trayMenuOwner){DestroyWindow(a.trayMenuOwner);a.trayMenuOwner=nullptr;}PostQuitMessage(0);return 0;
  }return DefWindowProcW(hwnd,msg,w,l);
 }
 int run(HINSTANCE h,int show){instance=h;app=this;InitializeCriticalSection(&deadlineLock);stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);dueEvent=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!stopEvent||!dueEvent)throw std::runtime_error("Timer scheduler unavailable");
  INITCOMMONCONTROLSEX common{sizeof(common),ICC_STANDARD_CLASSES|ICC_LISTVIEW_CLASSES|ICC_UPDOWN_CLASS|ICC_BAR_CLASSES};InitCommonControlsEx(&common);icon=LoadIconW(instance,MAKEINTRESOURCEW(1));
  WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.hInstance=instance;cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);cls.hIcon=cls.hIconSm=icon;cls.style=CS_HREDRAW|CS_VREDRAW;cls.lpfnWndProc=mainProc;cls.lpszClassName=CLASS;RegisterClassExW(&cls);cls.style=0;cls.lpfnWndProc=breakProc;cls.lpszClassName=BREAK_CLASS;RegisterClassExW(&cls);cls.style=CS_HREDRAW|CS_VREDRAW;cls.lpfnWndProc=paneProc;cls.lpszClassName=L"EyeBreakReminder.Settings";RegisterClassExW(&cls);cls.style=0;
  cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=TRAY_MENU_CLASS;RegisterClassExW(&cls);
  trayMenuOwner=CreateWindowExW(WS_EX_TOOLWINDOW,TRAY_MENU_CLASS,L"",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,nullptr);if(!trayMenuOwner)throw std::runtime_error("Tray menu window unavailable");
  main=CreateWindowExW(WS_EX_APPWINDOW|WS_EX_CONTROLPARENT,CLASS,L"Eye Break Reminder",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,820,720,nullptr,nullptr,instance,nullptr);if(!main)throw std::runtime_error("Window unavailable");audio=std::make_unique<Audio>(main);audio->changed=[this]{postPreviewRefresh();};load();dpi=GetDpiForWindow(main);
  auto list=monitors();Monitor selected=preferred(settings,main);for(auto&m:list)if(settings.x>=m.work.left&&settings.x<m.work.right&&settings.y>=m.work.top&&settings.y<m.work.bottom)selected=m;RECT work=selected.work;
  int width=std::min(px(settings.width),int(work.right-work.left)),height=std::min(px(settings.height),int(work.bottom-work.top));int x=settings.x==-32000?work.left+(work.right-work.left-width)/2:std::clamp(settings.x,int(work.left),int(work.right-width));int y=settings.y==-32000?work.top+(work.bottom-work.top-height)/2:std::clamp(settings.y,int(work.top),int(work.bottom-height));SetWindowPos(main,nullptr,x,y,width,height,SWP_NOZORDER);
  createControls();applyTheme();addTray();WTSRegisterSessionNotification(main,NOTIFY_FOR_THIS_SESSION);
  engine->changed=[this]{changed();};engine->due=[this](auto cycle,bool alarm){breakDue(cycle,alarm);};engine->breakCompleted=[this](auto cycle,bool alarm){breakCompleted(cycle,alarm);};engine->ended=[this](Record record){if(settings.history){history.push_back(record);if(history.size()>10000)history.erase(history.begin());saveHistory();updateHistory();}};
  worker=CreateThread(nullptr,0,Application::work,this,0,nullptr);if(!worker)throw std::runtime_error("Timer worker unavailable");changed();SetTimer(main,CHECKPOINT,30000,nullptr);ShowWindow(main,show);UpdateWindow(main);updateRenderTimer();SetFocus(nav[0]);
  HWND lastFocus=nullptr;MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(message.message==WM_MOUSEWHEEL&&handleWheel(message))continue;if(message.message==WM_KEYDOWN&&GetKeyState(VK_CONTROL)<0){if(message.wParam=='R'){engine->reset();continue;}if(message.wParam=='B'&&GetKeyState(VK_SHIFT)<0){engine->takeBreak();continue;}if(message.wParam==VK_OEM_COMMA){showMain();switchPage(2);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_RETURN){HWND focus=GetFocus();wchar_t clsName[32]{};GetClassNameW(focus,clsName,32);if(wcscmp(clsName,L"Button")==0){SendMessageW(focus,BM_CLICK,0,0);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_ESCAPE&&breakWindow){engine->finish(false);continue;}
   HWND dialog=breakWindow&&IsChild(breakWindow,GetFocus())?breakWindow:main;if(!IsDialogMessageW(dialog,&message)){TranslateMessage(&message);DispatchMessageW(&message);}HWND focus=GetFocus();if(focus!=lastFocus){lastFocus=focus;ensureFocused(focus);ensureBreakVisible(focus);}}
  audio->changed=nullptr;audio.reset();if(backgroundBrush)DeleteObject(backgroundBrush);if(surfaceBrush)DeleteObject(surfaceBrush);if(normalFont)DeleteObject(normalFont);
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
 HANDLE mutex=CreateMutexW(nullptr,FALSE,L"Local\\EyeBreakReminder.Native.1");if(!mutex)return 1;if(GetLastError()==ERROR_ALREADY_EXISTS){for(int i=0;i<12;++i){HWND existing=FindWindowW(CLASS,nullptr);if(existing){DWORD pid=0;GetWindowThreadProcessId(existing,&pid);AllowSetForegroundWindow(pid);PostMessageW(existing,RegisterWindowMessageW(L"EyeBreakReminder.Activate.Native.1"),0,0);break;}Sleep(100);}CloseHandle(mutex);return 0;}
 HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);ULONG_PTR graphics=0;Gdiplus::GdiplusStartupInput input;if(Gdiplus::GdiplusStartup(&graphics,&input,nullptr)!=Gdiplus::Ok){CloseHandle(mutex);return 1;}
 int result=1;try{Application app;result=app.run(instance,show);}catch(const std::exception&){MessageBoxW(nullptr,L"Eye Break Reminder couldn't start. Please close the app and try again.",L"Eye Break Reminder",MB_OK|MB_ICONERROR);}
 Gdiplus::GdiplusShutdown(graphics);if(SUCCEEDED(com))CoUninitialize();CloseHandle(mutex);return result;
}
