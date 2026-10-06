#include "windows_services.hpp"
#include <array>
using namespace eye;
using namespace eye::win;
namespace {
constexpr wchar_t CLASS[]=L"EyeBreakReminder.Native";
constexpr wchar_t BREAK_CLASS[]=L"EyeBreakReminder.Break";
constexpr wchar_t TRAY_MENU_CLASS[]=L"EyeBreakReminder.TrayMenu";
constexpr UINT TRAY_MESSAGE=WM_APP+1, ENGINE_MESSAGE=WM_APP+2;
constexpr int NAV_TIMER=10,NAV_HISTORY=11,NAV_SETTINGS=12,PAUSE=20,RESET=21,TAKE_BREAK=22,COMPLETE=23,SKIP=24,SNOOZE1=25,SNOOZE3=26,SNOOZE5=27;
constexpr int COUNTDOWN=40,TIMER_STATE=41,COUNT_CAPTION=42,BREAK_TITLE=43,BREAK_INSTRUCTION=44,BREAK_GUIDANCE=45,HISTORY_TOGGLE=30,CLEAR_HISTORY=31,ALARM_TOGGLE=32,WORK=100,BREAK_SECONDS=101,SOUND=102,VOLUME=103,MODE=104,MONITOR=105,THEME=106,REPEAT=107,NOTIFY=108,SNOOZE=109,AUTO_START=110,STARTUP=111,TRAY=112,RESTORE=113,PAUSE_LOCK=114,SELECT_MONITOR=115,PREVIEW=116,STOP_AUDIO=117,RESET_SETTINGS=118;
constexpr UINT_PTR RENDER=1,CHECKPOINT=2;
struct Control {HWND handle{};int id=0;int page=0;int height=36;bool full=false;HWND buddySpin{};bool heading=false;};
struct Colors {COLORREF background=RGB(247,248,250),surface=RGB(255,255,255),hover=RGB(239,243,249),foreground=RGB(24,30,42),secondary=RGB(93,103,119),line=RGB(215,222,232),accent=RGB(37,99,235);bool dark=false,contrast=false;};
class Application {
public:
 HINSTANCE instance{};HWND main{},breakWindow{},trayMenuOwner{};HICON icon{};HFONT normalFont{},headingFont{},titleFont{},countFont{},breakFont{},breakTitleFont{},breakCountFont{};int countSize=0;HBRUSH backgroundBrush{},surfaceBrush{};
 Settings settings;std::unique_ptr<Engine> engine;std::unique_ptr<Audio> audio;std::vector<Record> history;
 std::vector<Control> controls;std::array<HWND,3> nav{};HWND historyList{},settingsPane{};std::vector<Monitor> displays;
 Colors colors;std::wstring directory;UINT dpi=96;double textScale=1;bool hidden=false,locked=false,sleeping=false,quitting=false,quietBreak=false,loading=false,trayAdded=false,dirtySettings=false,saveWarned=false;
 int page=0,settingsScroll=0,settingsHeight=0,breakScroll=0,breakHeight=0;std::uint64_t notifiedCycle=0;NOTIFYICONDATAW trayData{};
 HANDLE dueEvent{},stopEvent{};HANDLE worker{};UINT activateMessage=RegisterWindowMessageW(L"EyeBreakReminder.Activate.Native.1");UINT quitMessage=RegisterWindowMessageW(L"EyeBreakReminder.Exit.Native.1");UINT explorerMessage=RegisterWindowMessageW(L"TaskbarCreated");
 double deadline=0;CRITICAL_SECTION deadlineLock{};RECT normalBounds{};bool haveNormalBounds=false;
 static Application* app;
 int px(double value)const{return int(std::round(value*dpi/96.0));}
 int fontHeight(int points)const{return -int(std::round(points*dpi/72.0*textScale));}
 void error(const wchar_t* message){inform(main,L"Eye Break Reminder",message);}
 LRESULT drawButton(NMHDR* notification){
  if(!notification||notification->code!=NM_CUSTOMDRAW||colors.contrast)return CDRF_DODEFAULT;
  HWND button=notification->hwndFrom;wchar_t name[32]{};GetClassNameW(button,name,32);if(wcscmp(name,L"Button")!=0)return CDRF_DODEFAULT;
  auto draw=reinterpret_cast<NMCUSTOMDRAW*>(notification);if(draw->dwDrawStage!=CDDS_PREPAINT)return CDRF_DODEFAULT;
  DWORD style=DWORD(GetWindowLongPtrW(button,GWL_STYLE)),type=style&BS_TYPEMASK;
  bool checkbox=type==BS_AUTOCHECKBOX;
  if(!checkbox&&type!=BS_PUSHBUTTON&&type!=BS_DEFPUSHBUTTON&&!(style&BS_PUSHLIKE))return CDRF_DODEFAULT;
  int id=GetDlgCtrlID(button),scale=int(GetDpiForWindow(button));auto bpx=[&](int n){return std::max(1,n*scale/96);};
  bool enabled=IsWindowEnabled(button)!=FALSE,pressed=(draw->uItemState&CDIS_SELECTED)!=0;
  bool selected=SendMessageW(button,BM_GETCHECK,0,0)==BST_CHECKED,hot=(draw->uItemState&CDIS_HOT)!=0;
  bool primary=id==TAKE_BREAK||id==COMPLETE;
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
  UINT flags=checkbox?DT_LEFT|DT_WORDBREAK:DT_CENTER|DT_VCENTER|DT_SINGLELINE;LRESULT cues=SendMessageW(button,WM_QUERYUISTATE,0,0);if(cues&UISF_HIDEACCEL)flags|=DT_HIDEPREFIX;
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
  if(titleFont)DeleteObject(titleFont);
  normalFont=CreateFontW(fontHeight(11),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  headingFont=CreateFontW(fontHeight(15),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  titleFont=CreateFontW(fontHeight(19),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI Variable");
  for(auto&c:controls)SendMessageW(c.handle,WM_SETFONT,reinterpret_cast<WPARAM>(c.heading?headingFont:normalFont),TRUE);
  for(auto h:nav)if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(normalFont),TRUE);
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
  for(auto&c:controls){wchar_t clsName[32]{};GetClassNameW(c.handle,clsName,32);if(wcscmp(clsName,L"Button")==0)SetWindowTheme(c.handle,nullptr,nullptr);InvalidateRect(c.handle,nullptr,TRUE);}
  for(auto h:nav)if(h)InvalidateRect(h,nullptr,TRUE);
  if(historyList){ListView_SetBkColor(historyList,colors.background);ListView_SetTextBkColor(historyList,colors.background);ListView_SetTextColor(historyList,colors.foreground);}
  InvalidateRect(main,nullptr,TRUE);if(settingsPane)InvalidateRect(settingsPane,nullptr,TRUE);if(breakWindow)InvalidateRect(breakWindow,nullptr,TRUE);
 }
 HWND control(const wchar_t*cls,const wchar_t*text,DWORD style,int id,int onPage,int height=36,HWND parent=nullptr){
  // The settings pane controls inherit page visibility from their parent.
  HWND h=CreateWindowExW((wcscmp(cls,L"EDIT")==0)?WS_EX_CLIENTEDGE:0,cls,text,WS_CHILD|WS_VISIBLE|(wcscmp(cls,L"STATIC")==0?0:WS_TABSTOP)|style,0,0,1,1,parent?parent:main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance,nullptr);
  if(!h)throw std::runtime_error("Could not create native control");
  SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(normalFont),TRUE);controls.push_back({h,id,onPage,height,false});return h;
 }
 HWND label(const wchar_t*text,int onPage,HWND parent=nullptr,bool heading=false){HWND h=control(L"STATIC",text,SS_LEFT,-1,onPage,heading?44:28,parent);auto&c=controls.back();c.full=true;c.heading=heading;SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(heading?headingFont:normalFont),TRUE);return h;}
 void checkbox(const wchar_t*text,int id,int onPage,bool checked,HWND parent){HWND h=control(L"BUTTON",text,BS_AUTOCHECKBOX|BS_MULTILINE,id,onPage,40,parent);SendMessageW(h,BM_SETCHECK,checked?BST_CHECKED:BST_UNCHECKED,0);controls.back().full=true;}
 void combo(const wchar_t*labelText,int id,const std::vector<std::wstring>&items,int selected){
  label(labelText,2,settingsPane);HWND h=control(WC_COMBOBOXW,L"",CBS_DROPDOWNLIST|WS_VSCROLL,id,2,36,settingsPane);for(auto&s:items)SendMessageW(h,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(s.c_str()));SendMessageW(h,CB_SETCURSEL,selected,0);
 }
 void number(const wchar_t*labelText,int id,int value,int low,int high){label(labelText,2,settingsPane);HWND h=control(L"EDIT",std::to_wstring(value).c_str(),ES_NUMBER|ES_AUTOHSCROLL,id,2,36,settingsPane);SendMessageW(h,EM_SETLIMITTEXT,3,0);SendMessageW(h,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELPARAM(px(10),px(10)));
  HWND spin=CreateWindowExW(0,UPDOWN_CLASSW,L"",WS_CHILD|WS_VISIBLE|UDS_ALIGNRIGHT|UDS_SETBUDDYINT|UDS_ARROWKEYS,0,0,0,0,settingsPane,nullptr,instance,nullptr);if(!spin)throw std::runtime_error("Could not create number control");controls.back().buddySpin=spin;SendMessageW(spin,UDM_SETBUDDY,reinterpret_cast<WPARAM>(h),0);SendMessageW(spin,UDM_SETRANGE32,low,high);SendMessageW(spin,UDM_SETPOS32,0,value);}
 HWND find(int id){for(auto&c:controls)if(c.id==id)return c.handle;return nullptr;}
 void buildSettings(){
  loading=true;for(auto it=controls.begin();it!=controls.end();){if(it->page==2){DestroyWindow(it->handle);it=controls.erase(it);}else ++it;}
  // Buddy spin controls are recreated with their edits.
  EnumChildWindows(settingsPane,[](HWND child,LPARAM)->BOOL{wchar_t name[64]{};GetClassNameW(child,name,64);if(wcscmp(name,UPDOWN_CLASSW)==0)DestroyWindow(child);return TRUE;},0);
  label(L"Timer",2,settingsPane,true);number(L"Work interval (minutes)",WORK,settings.workMinutes,1,180);number(L"Break duration (seconds)",BREAK_SECONDS,settings.breakSeconds,5,300);
  label(L"Changes apply to the next cycle. Reset starts a fresh work interval.",2,settingsPane);
  label(L"Alarm",2,settingsPane,true);checkbox(L"Alarm enabled",ALARM_TOGGLE,2,settings.alarm,settingsPane);
  combo(L"Alarm sound",SOUND,{L"Gentle",L"Bell",L"Chime",L"Clear",L"Soft"},settings.sound);
  label(L"Alarm volume",2,settingsPane);HWND volume=control(TRACKBAR_CLASSW,L"",TBS_AUTOTICKS|TBS_TOOLTIPS,VOLUME,2,40,settingsPane);SendMessageW(volume,TBM_SETRANGE,TRUE,MAKELONG(0,100));SendMessageW(volume,TBM_SETPOS,TRUE,settings.volume);SetWindowTextW(volume,L"Alarm volume, percent");
  checkbox(L"Repeat until the break ends or is acknowledged",REPEAT,2,settings.repeat,settingsPane);
  control(L"BUTTON",L"Preview alarm",BS_PUSHBUTTON,PREVIEW,2,36,settingsPane);control(L"BUTTON",L"Stop preview",BS_PUSHBUTTON,STOP_AUDIO,2,36,settingsPane);
  label(L"Reminders",2,settingsPane,true);checkbox(L"Windows notifications",NOTIFY,2,settings.notifications,settingsPane);checkbox(L"Allow snooze (1, 3 or 5 minutes)",SNOOZE,2,settings.snooze,settingsPane);
  combo(L"Break presentation",MODE,{L"Normal window",L"Compact reminder",L"Fullscreen reminder (opt in)"},settings.mode);combo(L"Preferred monitor",MONITOR,{L"Active display",L"Primary display",L"Selected display"},settings.monitor);
  displays=monitors();std::vector<std::wstring> names;int chosen=0;for(std::size_t i=0;i<displays.size();++i){names.push_back(L"Display "+std::to_wstring(i+1)+(displays[i].primary?L" (primary)":L""));if(utf8(displays[i].device)==settings.selectedMonitor)chosen=int(i);}combo(L"Selected display",SELECT_MONITOR,names,chosen);
  label(L"Appearance",2,settingsPane,true);combo(L"Theme",THEME,{L"Use system setting",L"Light",L"Dark"},settings.theme);
  label(L"Behaviour",2,settingsPane,true);checkbox(L"Start timer automatically on launch",AUTO_START,2,settings.autoStart,settingsPane);checkbox(L"Start with Windows",STARTUP,2,settings.startup,settingsPane);
  label(L"Open Eye Break Reminder automatically when you sign in.",2,settingsPane);checkbox(L"Minimize to system tray",TRAY,2,settings.tray,settingsPane);label(L"Closing keeps reminders active. Choose Exit in the tray menu to quit.",2,settingsPane);
  checkbox(L"Resume countdown when reopening the app",RESTORE,2,settings.restore,settingsPane);label(L"Reinstalling after uninstall starts a fresh work interval. Preferences and history are kept.",2,settingsPane);checkbox(L"Pause while workstation is locked",PAUSE_LOCK,2,settings.pauseLocked,settingsPane);
  label(L"Sleep counts as elapsed work time. Wake shows at most one reminder. Paused timers stay paused.",2,settingsPane);
  label(L"Accessibility",2,settingsPane,true);label(L"Uses Windows text scaling, high contrast and keyboard focus. Ctrl+R: Reset. Ctrl+Shift+B: Take break. Ctrl+comma: Settings.",2,settingsPane);
  label(L"About",2,settingsPane,true);label(L"Eye Break Reminder\nVersion 1.0.3 · x64\nWindows 11",2,settingsPane);
  label(L"All data stays on this device. No internet, telemetry, account, camera or microphone.",2,settingsPane);
  control(L"BUTTON",L"Reset all settings",BS_PUSHBUTTON,RESET_SETTINGS,2,36,settingsPane);loading=false;layout();
 }
 void createControls(){
  dpi=GetDpiForWindow(main);createFonts();
  for(int i=0;i<3;++i){nav[i]=CreateWindowExW(0,L"BUTTON",i==0?L"&Timer":i==1?L"&History":L"&Settings",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTORADIOBUTTON|BS_PUSHLIKE|(i==0?WS_GROUP:0),0,0,0,0,main,reinterpret_cast<HMENU>(static_cast<INT_PTR>(NAV_TIMER+i)),instance,nullptr);SendMessageW(nav[i],WM_SETFONT,reinterpret_cast<WPARAM>(normalFont),TRUE);}
  control(L"STATIC",L"Running",SS_CENTER|SS_CENTERIMAGE,TIMER_STATE,0);control(L"STATIC",L"Next eye break",SS_CENTER|SS_CENTERIMAGE,COUNT_CAPTION,0);control(L"STATIC",L"20:00",SS_CENTER|SS_CENTERIMAGE,COUNTDOWN,0);
  control(L"BUTTON",L"Take a break now",BS_DEFPUSHBUTTON,TAKE_BREAK,0);control(L"BUTTON",L"Pause",BS_PUSHBUTTON,PAUSE,0);control(L"BUTTON",L"Reset",BS_PUSHBUTTON,RESET,0);
  historyList=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"Eye break history",WS_CHILD|WS_TABSTOP|LVS_REPORT|LVS_SINGLESEL|LVS_SHOWSELALWAYS,0,0,1,1,main,reinterpret_cast<HMENU>(200),instance,nullptr);ListView_SetExtendedListViewStyle(historyList,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER);
  for(int i=0;i<3;++i){LVCOLUMNW col{};col.mask=LVCF_TEXT|LVCF_WIDTH|LVCF_SUBITEM;col.pszText=const_cast<LPWSTR>(i==0?L"Date":i==1?L"Break":L"Seconds");col.cx=px(i==0?240:140);col.iSubItem=i;ListView_InsertColumn(historyList,i,&col);}
  checkbox(L"Save history on this device",HISTORY_TOGGLE,1,settings.history,main);control(L"BUTTON",L"Clear history",BS_PUSHBUTTON,CLEAR_HISTORY,1);
  settingsPane=CreateWindowExW(WS_EX_CONTROLPARENT,L"EyeBreakReminder.Settings",L"Settings",WS_CHILD|WS_VSCROLL|WS_CLIPCHILDREN,0,0,1,1,main,nullptr,instance,nullptr);buildSettings();switchPage(0);
 }
 void switchPage(int next){page=next;for(int i=0;i<3;++i){SendMessageW(nav[i],BM_SETCHECK,i==page?BST_CHECKED:BST_UNCHECKED,0);InvalidateRect(nav[i],nullptr,TRUE);}
  for(auto&c:controls)if(c.page!=2)ShowWindow(c.handle,c.page==page?SW_SHOW:SW_HIDE);
  ShowWindow(settingsPane,page==2?SW_SHOW:SW_HIDE);ShowWindow(historyList,page==1?SW_SHOW:SW_HIDE);if(page==1)updateHistory();layout();updateRenderTimer();InvalidateRect(main,nullptr,TRUE);}
 void layout(){
  if(!main||!settingsPane)return;
  RECT client{};GetClientRect(main,&client);int w=client.right,h=client.bottom,pad=px(28),gap=px(12),bh=px(std::max(36.0,30.0*textScale));
  int navWidth=std::max(px(110),std::min(px(148),(w-2*pad-2*gap)/3));for(int i=0;i<3;++i)MoveWindow(nav[i],pad+i*(navWidth+gap),px(16),navWidth,bh,TRUE);
  int top=px(16)+bh+px(28);
  if(page==0){int y=std::max(top+px(285),h-px(150)-2*bh-gap);int buttonWidth=std::min(w-2*pad,px(280*std::sqrt(textScale)));MoveWindow(find(TAKE_BREAK),(w-buttonWidth)/2,y,buttonWidth,bh,TRUE);int secondWidth=(buttonWidth-gap)/2;MoveWindow(find(PAUSE),(w-buttonWidth)/2,y+bh+gap,secondWidth,bh,TRUE);MoveWindow(find(RESET),(w-buttonWidth)/2+secondWidth+gap,y+bh+gap,secondWidth,bh,TRUE);
   int timerTop=px(16)+bh+px(22),stateBottom=timerTop+px(88);
   int diameter=std::min({px(272),w-px(100),std::max(px(160),y-stateBottom-px(18))});int left=(w-diameter)/2,ty=stateBottom+px(8);
   MoveWindow(find(TIMER_STATE),pad,timerTop+px(50),w-2*pad,px(38),TRUE);
   MoveWindow(find(COUNTDOWN),left,ty+diameter/3,diameter,diameter/3,TRUE);
   MoveWindow(find(COUNT_CAPTION),left,ty+diameter*2/3,diameter,px(40),TRUE);
   int size=std::min(px(56*std::sqrt(textScale)),diameter/4);if(size!=countSize){HFONT previous=countFont;countSize=size;countFont=CreateFontW(-size,0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI Variable");SendMessageW(find(COUNTDOWN),WM_SETFONT,reinterpret_cast<WPARAM>(countFont),TRUE);if(previous)DeleteObject(previous);}
  }
  if(page==1){int listTop=top+px(135)*int(std::ceil(textScale));int listHeight=std::max(px(80),h-listTop-pad-bh-gap);MoveWindow(historyList,pad,listTop,w-2*pad,listHeight,TRUE);MoveWindow(find(HISTORY_TOGGLE),pad,listTop+listHeight+gap,std::max(px(240),w-2*pad-px(150)),bh,TRUE);MoveWindow(find(CLEAR_HISTORY),w-pad-px(140),listTop+listHeight+gap,px(140),bh,TRUE);}
  MoveWindow(settingsPane,pad,top,w-2*pad,h-top-pad,TRUE);
  RECT pane{};GetClientRect(settingsPane,&pane);int inset=px(12),y=px(8);int width=std::max(100,int(pane.right)-2*inset);
  for(auto&c:controls)if(c.page==2){if(c.heading&&y>px(8))y+=px(16);int height=px(int(c.height*textScale));if(c.id==-1){wchar_t content[1024]{};GetWindowTextW(c.handle,content,1024);HDC dc=GetDC(c.handle);auto previous=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(c.handle,WM_GETFONT,0,0)));RECT measured{0,0,width,0};DrawTextW(dc,content,-1,&measured,DT_CALCRECT|DT_WORDBREAK);SelectObject(dc,previous);ReleaseDC(c.handle,dc);height=std::max(height,int(measured.bottom)+px(8));}int controlWidth=c.full?width:std::min(width,px(420));
   wchar_t cls[64]{};GetClassNameW(c.handle,cls,64);int nativeHeight=wcscmp(cls,WC_COMBOBOXW)==0?height+px(220):height;int spinWidth=c.buddySpin?px(24):0;MoveWindow(c.handle,inset,y-settingsScroll,controlWidth-spinWidth,nativeHeight,TRUE);if(c.buddySpin)SetWindowPos(c.buddySpin,nullptr,inset+controlWidth-spinWidth,y-settingsScroll,spinWidth,height,SWP_NOZORDER);
   y+=height+px(c.id==-1?4:12);}
  settingsHeight=y;SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS,0,settingsHeight,UINT(std::max(1L,pane.bottom)),settingsScroll,0};SetScrollInfo(settingsPane,SB_VERT,&info,TRUE);
 }
 void scroll(int amount){RECT r{};GetClientRect(settingsPane,&r);settingsScroll=std::clamp(settingsScroll+amount,0,std::max(0,settingsHeight-int(r.bottom)));layout();InvalidateRect(settingsPane,nullptr,TRUE);}
 void ensureFocused(HWND h){if(page!=2||GetParent(h)!=settingsPane)return;RECT r{};GetWindowRect(h,&r);MapWindowPoints(nullptr,settingsPane,reinterpret_cast<POINT*>(&r),2);RECT client{};GetClientRect(settingsPane,&client);if(r.top<0)scroll(r.top-px(8));else if(r.bottom>client.bottom)scroll(r.bottom-client.bottom+px(8));}
 void text(HDC dc,const std::wstring&str,RECT area,HFONT font,COLORREF color,UINT flags=DT_LEFT|DT_WORDBREAK){SelectObject(dc,font);SetTextColor(dc,color);SetBkMode(dc,TRANSPARENT);DrawTextW(dc,str.c_str(),int(str.size()),&area,flags);}
 void paint(HWND hwnd,bool isBreak){
  PAINTSTRUCT ps{};HDC target=BeginPaint(hwnd,&ps);RECT r{};GetClientRect(hwnd,&r);HDC dc=CreateCompatibleDC(target);HBITMAP bitmap=CreateCompatibleBitmap(target,std::max(1L,r.right),std::max(1L,r.bottom));auto previous=SelectObject(dc,bitmap);FillRect(dc,&r,backgroundBrush);auto snap=engine->snapshot();
  if(isBreak){ // Native STATIC controls render all break content.
  }else if(page==0){
   int top=px(16)+px(std::max(36.0,30.0*textScale))+px(22);RECT title{px(28),top,r.right-px(28),top+px(44)};text(dc,L"Timer",title,titleFont,colors.foreground);
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
  }else if(page==1){int top=px(16)+px(std::max(36.0,30.0*textScale))+px(28);RECT title{px(28),top,r.right-px(28),top+px(42)};text(dc,L"History",title,titleFont,colors.foreground);
   std::time_t stamp=std::time_t(utc());std::tm tm{};localtime_s(&tm,&stamp);int today=calendarDay(stamp);auto stats=statistics(history,today,today-(tm.tm_wday+6)%7,calendarDay);
   std::wstring summary=history.empty()?L"No breaks recorded yet.\nCompleted eye breaks will appear here.":L"Today: "+std::to_wstring(stats.todayCompleted)+L" completed · "+std::to_wstring(stats.todaySkipped)+L" skipped · "+std::to_wstring(int(std::round(stats.completion)))+L"% completed\nThis week: "+std::to_wstring(stats.weekCompleted)+L" completed · "+std::to_wstring(stats.streak)+L" day streak\nTotal retained: "+std::to_wstring(stats.totalCompleted)+L" completed";
   RECT area{px(28),title.bottom+px(8),r.right-px(28),title.bottom+px(100)*int(std::ceil(textScale))};text(dc,summary,area,normalFont,colors.secondary);
  }
  BitBlt(target,0,0,r.right,r.bottom,dc,0,0,SRCCOPY);SelectObject(dc,previous);DeleteObject(bitmap);DeleteDC(dc);EndPaint(hwnd,&ps);
 }
 void updateAccessibleTimer(){auto snap=engine->snapshot();auto set=[&](int id,const std::wstring&value){HWND h=find(id);if(!h)return;wchar_t old[160]{};GetWindowTextW(h,old,160);if(value!=old)SetWindowTextW(h,value.c_str());};set(COUNTDOWN,timeText(snap.remaining));set(COUNT_CAPTION,snap.phase==Phase::Break?L"Eye break":L"Next eye break");set(TIMER_STATE,snap.paused?L"Paused":snap.phase==Phase::Break?L"Rest your eyes":snap.phase==Phase::Snooze?L"Snoozed — next reminder below":L"Running");}
 void updateHistory(){if(!historyList)return;ListView_DeleteAllItems(historyList);int row=0;for(auto it=history.rbegin();it!=history.rend()&&row<100;++it,++row){auto date=formatDate(it->at);LVITEMW item{};item.mask=LVIF_TEXT;item.iItem=row;item.pszText=date.data();ListView_InsertItem(historyList,&item);ListView_SetItemText(historyList,row,1,const_cast<LPWSTR>(it->completed?L"Completed":L"Skipped"));auto seconds=std::to_wstring(int(std::round(it->seconds)));ListView_SetItemText(historyList,row,2,seconds.data());}InvalidateRect(main,nullptr,TRUE);}
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
 void dismissBreak(){audio->stop();clearNotification();if(breakWindow){quietBreak=true;HWND old=breakWindow;breakWindow=nullptr;DestroyWindow(old);quietBreak=false;if(breakFont){DeleteObject(breakFont);breakFont=nullptr;}if(breakTitleFont){DeleteObject(breakTitleFont);breakTitleFont=nullptr;}if(breakCountFont){DeleteObject(breakCountFont);breakCountFont=nullptr;}}updateRenderTimer();}
 void showBreak(){
  if(breakWindow||engine->snapshot().phase!=Phase::Break||locked||sleeping||engine->isSuspended())return;
  auto monitor=preferred(settings,GetForegroundWindow());RECT work=monitor.work;UINT monitorDpi=dpi;
  // Place first, then read the window's actual per-monitor DPI before sizing it.
  DWORD style=settings.mode==2?WS_POPUP|WS_CLIPCHILDREN:WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX|WS_CLIPCHILDREN;
  breakWindow=CreateWindowExW(WS_EX_APPWINDOW,BREAK_CLASS,L"Rest your eyes — Eye Break Reminder",style|WS_VSCROLL,work.left,work.top,100,100,nullptr,nullptr,instance,nullptr);
  if(!breakWindow){error(L"The break reminder couldn't open. Please rest your eyes for 20 seconds.");return;}
  monitorDpi=GetDpiForWindow(breakWindow);breakScroll=0;
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
 void scrollBreak(int amount){if(!breakWindow)return;RECT r{};GetClientRect(breakWindow,&r);breakScroll=std::clamp(breakScroll+amount,0,std::max(0,breakHeight-int(r.bottom)));layoutBreak();}
 void layoutBreak(){
  if(!breakWindow)return;
  RECT r{};GetClientRect(breakWindow,&r);int scale=int(GetDpiForWindow(breakWindow));auto bpx=[&](double n){return int(n*scale/96.0);};
  int pad=bpx(28),gap=bpx(12),bh=bpx(40*textScale),width=std::min(bpx(380),int(r.right)-2*pad),x=(r.right-width)/2,y=pad;
  auto place=[&](int id,int height){MoveWindow(GetDlgItem(breakWindow,id),x,y-breakScroll,width,height,TRUE);y+=height+gap;};
  place(BREAK_TITLE,bpx(42*textScale));place(BREAK_INSTRUCTION,bpx(48*textScale));place(COUNTDOWN,bpx(96*std::sqrt(textScale)));place(BREAK_GUIDANCE,bpx(48*textScale));place(COMPLETE,bh);
  int skipWidth=settings.snooze?width/4:width;MoveWindow(GetDlgItem(breakWindow,SKIP),x,y-breakScroll,skipWidth-4,bh,TRUE);
  if(settings.snooze){int widths[3]={width/3,width/5,width-width/4-width/3-width/5};int left=x+width/4;int ids[3]={SNOOZE1,SNOOZE3,SNOOZE5};for(int i=0;i<3;++i){MoveWindow(GetDlgItem(breakWindow,ids[i]),left,y-breakScroll,widths[i]-4,bh,TRUE);left+=widths[i];}}
  breakHeight=y+bh+pad;SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS,0,breakHeight,UINT(std::max(1L,r.bottom)),breakScroll,0};SetScrollInfo(breakWindow,SB_VERT,&info,TRUE);InvalidateRect(breakWindow,nullptr,TRUE);
 }
 void suspend(bool isLock){engine->suspend(isLock);dismissBreak();schedule();saveTimer();}
 void wake(){if(locked||sleeping)return;engine->wake();schedule();if(engine->snapshot().phase==Phase::Break)showBreak();}
 void exit(){if(quitting)return;quitting=true;saveSettings();saveTimer();dismissBreak();DestroyWindow(main);}
 LRESULT color(HDC dc,HWND child=nullptr,bool input=false){SetBkColor(dc,input?colors.surface:colors.background);COLORREF ink=colors.foreground;if(child&&reinterpret_cast<HFONT>(SendMessageW(child,WM_GETFONT,0,0))==headingFont&&!colors.contrast)ink=colors.accent;SetTextColor(dc,ink);return reinterpret_cast<LRESULT>(input?surfaceBrush:backgroundBrush);}
 static LRESULT CALLBACK paneProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;case WM_HSCROLL:if(reinterpret_cast<HWND>(l)==a.find(VOLUME)){a.settings.volume=int(SendMessageW(a.find(VOLUME),TBM_GETPOS,0,0));a.settingsChanged();if(LOWORD(w)==TB_ENDTRACK)a.saveSettings();}return 0;case WM_VSCROLL:{SCROLLINFO info{sizeof(info),SIF_ALL,0,0,0,0,0};GetScrollInfo(hwnd,SB_VERT,&info);int n=LOWORD(w);if(n==SB_LINEUP)a.scroll(-a.px(40));else if(n==SB_LINEDOWN)a.scroll(a.px(40));else if(n==SB_PAGEUP)a.scroll(-int(info.nPage));else if(n==SB_PAGEDOWN)a.scroll(int(info.nPage));else if(n==SB_THUMBTRACK)a.scroll(info.nTrackPos-a.settingsScroll);return 0;}case WM_MOUSEWHEEL:a.scroll(-GET_WHEEL_DELTA_WPARAM(w)*a.px(60)/WHEEL_DELTA);return 0;case WM_ERASEBKGND:{RECT r{};GetClientRect(hwnd,&r);FillRect(reinterpret_cast<HDC>(w),&r,a.backgroundBrush);return 1;}case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:case WM_CTLCOLORLISTBOX:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK breakProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:a.paint(hwnd,true);return 0;case WM_ERASEBKGND:return 1;case WM_SIZE:a.layoutBreak();return 0;case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
  case WM_VSCROLL:{SCROLLINFO info{sizeof(info),SIF_ALL,0,0,0,0,0};GetScrollInfo(hwnd,SB_VERT,&info);int n=LOWORD(w);if(n==SB_LINEUP)a.scrollBreak(-40);else if(n==SB_LINEDOWN)a.scrollBreak(40);else if(n==SB_PAGEUP)a.scrollBreak(-int(info.nPage));else if(n==SB_PAGEDOWN)a.scrollBreak(int(info.nPage));else if(n==SB_THUMBTRACK)a.scrollBreak(info.nTrackPos-a.breakScroll);return 0;}
  case WM_MOUSEWHEEL:a.scrollBreak(-GET_WHEEL_DELTA_WPARAM(w)*60/WHEEL_DELTA);return 0;
  case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CLOSE:if(!a.quietBreak){a.engine->finish(false);return 0;}break;case WM_DPICHANGED:{auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.layoutBreak();return 0;}}return DefWindowProcW(hwnd,msg,w,l);}
 static LRESULT CALLBACK mainProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){auto&a=*app;
  if(msg==a.activateMessage){a.showMain();return 0;}if(msg==a.quitMessage){a.exit();return 0;}if(msg==a.explorerMessage){a.addTray();a.updateTray();return 0;}
  switch(msg){case WM_NOTIFY:return a.drawButton(reinterpret_cast<NMHDR*>(l));case WM_PAINT:if(a.engine)a.paint(hwnd,false);else {PAINTSTRUCT p{};BeginPaint(hwnd,&p);EndPaint(hwnd,&p);}return 0;case WM_ERASEBKGND:return 1;
   case WM_SIZE:if(a.engine){if(w==SIZE_MINIMIZED){if(a.settings.tray)PostMessageW(hwnd,WM_APP+4,0,0);a.updateRenderTimer();}else {a.layout();a.updateRenderTimer();}}return 0;
   case WM_GETMINMAXINFO:{auto size=reinterpret_cast<MINMAXINFO*>(l);size->ptMinTrackSize={a.px(520),a.px(480)};return 0;}
   case WM_DPICHANGED:{a.dpi=HIWORD(w);auto r=reinterpret_cast<RECT*>(l);SetWindowPos(hwnd,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER);a.createFonts();a.layout();return 0;}
   case WM_SETTINGCHANGE:case WM_THEMECHANGED:if(a.engine){a.createFonts();a.applyTheme();a.layout();a.layoutBreak();a.updateRenderTimer();}return 0;
   case WM_DISPLAYCHANGE:if(a.page==2)a.buildSettings();return 0;
   case WM_COMMAND:a.command(LOWORD(w),HIWORD(w));return 0;
   case WM_TIMER:if(w==RENDER){a.engine->tick();a.updateAccessibleTimer();if(!a.hidden&&a.page==0)InvalidateRect(hwnd,nullptr,FALSE);if(a.breakWindow){auto time=timeText(a.engine->snapshot().remaining);wchar_t previous[32]{};GetWindowTextW(GetDlgItem(a.breakWindow,COUNTDOWN),previous,32);if(time!=previous)SetWindowTextW(GetDlgItem(a.breakWindow,COUNTDOWN),time.c_str());InvalidateRect(a.breakWindow,nullptr,FALSE);}}else if(w==CHECKPOINT){a.saveTimer();if(a.dirtySettings)a.saveSettings();}return 0;
   case ENGINE_MESSAGE:if(!a.quitting){a.engine->tick();a.schedule();}return 0;
   case WM_APP+3:a.error(L"Eye Break Reminder couldn't load some saved data. Defaults or a fresh timer have been restored.");return 0;
   case WM_APP+4:a.hideMain();return 0;
   case TRAY_MESSAGE:{UINT event=LOWORD(l);if(event==WM_LBUTTONUP||event==NIN_SELECT||event==NIN_KEYSELECT||event==NIN_BALLOONUSERCLICK)a.showMain();else if(event==WM_CONTEXTMENU||event==WM_RBUTTONUP)a.trayMenu({GET_X_LPARAM(w),GET_Y_LPARAM(w)});return 0;}
   case MM_WOM_DONE:if(a.audio&&a.audio->done(w,l)&&!a.audio->preview&&a.settings.repeat&&a.settings.alarm&&a.engine->snapshot().phase==Phase::Break&&!a.locked&&!a.sleeping)a.audio->play(a.settings);return 0;
   case WM_POWERBROADCAST:if(w==PBT_APMSUSPEND){a.sleeping=true;a.suspend(false);}else if(w==PBT_APMRESUMEAUTOMATIC||w==PBT_APMRESUMESUSPEND){a.sleeping=false;a.wake();}return TRUE;
   case WM_WTSSESSION_CHANGE:if(w==WTS_SESSION_LOCK){a.locked=true;a.suspend(true);}else if(w==WTS_SESSION_UNLOCK){a.locked=false;a.wake();}return 0;
   case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l));case WM_CTLCOLOREDIT:return a.color(reinterpret_cast<HDC>(w),reinterpret_cast<HWND>(l),true);
   case WM_QUERYENDSESSION:if(a.engine){a.saveSettings();a.saveTimer();}return TRUE;
   case WM_CLOSE:a.closeMain();return 0;
   case WM_DESTROY:a.quitting=true;KillTimer(hwnd,RENDER);KillTimer(hwnd,CHECKPOINT);if(a.stopEvent)SetEvent(a.stopEvent);if(a.worker){WaitForSingleObject(a.worker,3000);CloseHandle(a.worker);a.worker=nullptr;}if(a.trayAdded)Shell_NotifyIconW(NIM_DELETE,&a.trayData);WTSUnRegisterSessionNotification(hwnd);if(a.trayMenuOwner){DestroyWindow(a.trayMenuOwner);a.trayMenuOwner=nullptr;}PostQuitMessage(0);return 0;
  }return DefWindowProcW(hwnd,msg,w,l);
 }
 int run(HINSTANCE h,int show){instance=h;app=this;InitializeCriticalSection(&deadlineLock);stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);dueEvent=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!stopEvent||!dueEvent)throw std::runtime_error("Timer scheduler unavailable");
  INITCOMMONCONTROLSEX common{sizeof(common),ICC_STANDARD_CLASSES|ICC_LISTVIEW_CLASSES|ICC_UPDOWN_CLASS|ICC_BAR_CLASSES};InitCommonControlsEx(&common);icon=LoadIconW(instance,MAKEINTRESOURCEW(1));
  WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.hInstance=instance;cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);cls.hIcon=cls.hIconSm=icon;cls.lpfnWndProc=mainProc;cls.lpszClassName=CLASS;RegisterClassExW(&cls);cls.lpfnWndProc=breakProc;cls.lpszClassName=BREAK_CLASS;RegisterClassExW(&cls);cls.lpfnWndProc=paneProc;cls.lpszClassName=L"EyeBreakReminder.Settings";RegisterClassExW(&cls);
  cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=TRAY_MENU_CLASS;RegisterClassExW(&cls);
  trayMenuOwner=CreateWindowExW(WS_EX_TOOLWINDOW,TRAY_MENU_CLASS,L"",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,nullptr);if(!trayMenuOwner)throw std::runtime_error("Tray menu window unavailable");
  main=CreateWindowExW(WS_EX_APPWINDOW|WS_EX_CONTROLPARENT,CLASS,L"Eye Break Reminder",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,820,720,nullptr,nullptr,instance,nullptr);if(!main)throw std::runtime_error("Window unavailable");audio=std::make_unique<Audio>(main);load();dpi=GetDpiForWindow(main);
  auto list=monitors();Monitor selected=preferred(settings,main);for(auto&m:list)if(settings.x>=m.work.left&&settings.x<m.work.right&&settings.y>=m.work.top&&settings.y<m.work.bottom)selected=m;RECT work=selected.work;
  int width=std::min(px(settings.width),int(work.right-work.left)),height=std::min(px(settings.height),int(work.bottom-work.top));int x=settings.x==-32000?work.left+(work.right-work.left-width)/2:std::clamp(settings.x,int(work.left),int(work.right-width));int y=settings.y==-32000?work.top+(work.bottom-work.top-height)/2:std::clamp(settings.y,int(work.top),int(work.bottom-height));SetWindowPos(main,nullptr,x,y,width,height,SWP_NOZORDER);
  createControls();applyTheme();addTray();WTSRegisterSessionNotification(main,NOTIFY_FOR_THIS_SESSION);
  engine->changed=[this]{changed();};engine->due=[this](auto cycle,bool alarm){breakDue(cycle,alarm);};engine->ended=[this](Record record){if(settings.history){history.push_back(record);if(history.size()>10000)history.erase(history.begin());saveHistory();updateHistory();}};
  worker=CreateThread(nullptr,0,Application::work,this,0,nullptr);if(!worker)throw std::runtime_error("Timer worker unavailable");changed();SetTimer(main,CHECKPOINT,30000,nullptr);ShowWindow(main,show);UpdateWindow(main);updateRenderTimer();SetFocus(nav[0]);
  MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(message.message==WM_KEYDOWN&&GetKeyState(VK_CONTROL)<0){if(message.wParam=='R'){engine->reset();continue;}if(message.wParam=='B'&&GetKeyState(VK_SHIFT)<0){engine->takeBreak();continue;}if(message.wParam==VK_OEM_COMMA){showMain();switchPage(2);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_RETURN){HWND focus=GetFocus();wchar_t clsName[32]{};GetClassNameW(focus,clsName,32);if(wcscmp(clsName,L"Button")==0){SendMessageW(focus,BM_CLICK,0,0);continue;}}
   if(message.message==WM_KEYDOWN&&message.wParam==VK_ESCAPE&&breakWindow){engine->finish(false);continue;}
   HWND dialog=breakWindow&&IsChild(breakWindow,GetFocus())?breakWindow:main;if(!IsDialogMessageW(dialog,&message)){TranslateMessage(&message);DispatchMessageW(&message);}HWND focus=GetFocus();if(focus)ensureFocused(focus);if(breakWindow&&IsChild(breakWindow,focus)){RECT child{},view{};GetWindowRect(focus,&child);MapWindowPoints(nullptr,breakWindow,reinterpret_cast<POINT*>(&child),2);GetClientRect(breakWindow,&view);if(child.top<0)scrollBreak(child.top-8);else if(child.bottom>view.bottom)scrollBreak(child.bottom-view.bottom+8);}}
  audio.reset();if(backgroundBrush)DeleteObject(backgroundBrush);if(surfaceBrush)DeleteObject(surfaceBrush);if(normalFont)DeleteObject(normalFont);
  if(headingFont)DeleteObject(headingFont);
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
