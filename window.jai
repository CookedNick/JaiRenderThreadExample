mainWindow: HWND;
mainWindowW: s32;
mainWindowH: s32;

initMainWindow :: () {
	SetProcessDPIAware();
	timeBeginPeriod(1);
	hInstance := GetModuleHandleW(null);
	mainWindowClass: WNDCLASSEXW;
	mainWindowClassName := wide("main.window");
	{
		using mainWindowClass;
		cbSize = size_of(WNDCLASSEXW);
		style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
		mainWindowClass.hInstance = hInstance;
		hCursor = LoadCursorW(null, IDC_ARROW);
		lpszClassName = mainWindowClassName;
		hbrBackground = null; // CreateSolidBrush(0);
		lpfnWndProc = DefWindowProcW; // The default windowproc handles WM_CLOSE, which is all we need for now to stay responsive.
		RegisterClassExW(*mainWindowClass);
	}
	mainContext = *context;
	mainWindow = CreateWindowExW(0, mainWindowClassName, wide("A great window. Press Space to pause/resume animation."), WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, null, hInstance, null);
	UpdateWindow(mainWindow);
	
	GetClientRect(mainWindow, *reusableRECT);
	mainWindowW = reusableRECT.right - reusableRECT.left;
	mainWindowH = reusableRECT.bottom - reusableRECT.top;
}

mainWindowReceiveMessages :: () {
	while GetMessageW(*reusableMSG, null, 0, 0) {
		isRepeating :: (lParam: s64) -> bool {
			return cast(bool) ((lParam & (1 << 30)) >> 30);
		}
		
		isPressed :: (key: s32) -> bool {
			return cast(bool) (GetKeyState(key) & 0b100000000000000);
		}
		
		using reusableMSG;
		
		if message == {
			case WM_QUIT;
				return;
			case WM_KEYDOWN;
				if wParam == {
					case #char " ";
						if !isRepeating(lParam) {
							// Pause/Resume animation
							
							// I know everyone likes performance counters (Basic.current_time_monotonic() uses one),
							// but the value of GetTickCount64() is that it will give you the exact same timestamp
							// in milliseconds as the keydown event. So this timestamp is much closer to the actual time of keypress.
							// current_time_monotonic() will be a more precise measurement (sub-ms), but it will be report a later time than the event.
							eventT := GetTickCount64();
							EnterCriticalSection(*renderThreadCriticalSection);
							
							if renderFlags & .animating {
								print("?");
								// The animation is playing. Pause it.
								renderFlags -= .animating;
								
								// We're not going to render indefinitely anymore.
								renderFlags &= ~.renderIndefinitely;
								
								// But we do need to render this end frame.
								renderFlags |= .renderAtLeastOneMoreFrame;
								
								// And let's update the animation up to the timestamp of this keypress.
								updateBackgroundAnimation(eventT);
								
								// If the animation is playing, we can assume the render thread was active. So no need to wake.
								print("%\n", renderFlags);
							} else {
								print("!");
								// The animation is not playing. Start it.
								renderFlags |= (.renderIndefinitely | .animating);
								print("%\n", renderFlags);
								
								// Resuming from the time of the keypress.
								animationLastUpdateT = eventT;
								
								// Wake the render thread if needed.
								WakeConditionVariable(*renderThreadWakeConditionVariable);
							}
							
							LeaveCriticalSection(*renderThreadCriticalSection);
							continue;
						}
				}
		}
		
		TranslateMessage(*reusableMSG);
		DispatchMessageW(*reusableMSG);
	}
}

mainWindowSetMinimumSize :: (newMinimumW: s32, newMinimumH: s32) {
	// If needed, resize the window to at least the new minimum size.
	if mainWindowW < newMinimumW || mainWindowH < newMinimumH
		SetWindowPos(mainWindow, null, 0, 0, max(mainWindowW, newMinimumW), max(mainWindowH, newMinimumH), SWP_NOMOVE | SWP_NOZORDER);
	
	reusableRECT = .{0, 0, newMinimumW, newMinimumH};
	AdjustWindowRect(*reusableRECT, WS_OVERLAPPEDWINDOW, .FALSE);
	mainWindowMinimumSize = .{
		reusableRECT.right - reusableRECT.left,
		reusableRECT.bottom - reusableRECT.top
	};
}

mainWindowActivateWindowProc :: () {
	GWLP_WNDPROC :: -4;
	SetWindowLongPtrW(mainWindow, GWLP_WNDPROC, cast(s64) cast(*void) mainWindowProc);
}


GetTickCount64 :: () -> u64 #foreign kernel32;


#scope_file

#import "Windows";
user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";

// If you need to call Jai-things in the windowProc, you'll need to push this first.
// It seems to be 100% safe in my extensive testing to do this.
// It's even done this way in the Odin WindowProc example. (Odin also has a context.)
// At the end of the day, we're sticking to one context per thread. Seems fine.
// And... one last piece of evidence: The window proc is only ever called when we DispatchMessageW.
// So it's completely safe and predictable when this code will run. All good.
mainContext: *#Context;

mainWindowMinimumSize: POINT;

reusableMSG: MSG;
reusableRECT: RECT;
reusablePAINTSTRUCT: PAINTSTRUCT;

// mainWindowUpdateSize :: () #no_context {
// }

mainWindowProc :: (hWnd: *void, message: u32, wParam: u64, lParam: s64) -> s64 #c_call {
	if message == {
		case WM_PAINT;
			// Wake the render thread and tell it to draw a frame.
			EnterCriticalSection(*renderThreadCriticalSection);
			renderFlags |= .renderAtLeastOneMoreFrame;
			WakeConditionVariable(*renderThreadWakeConditionVariable);
			LeaveCriticalSection(*renderThreadCriticalSection);
			
			// Don't return 0.
			// Grok told me to return 0 and do BeginPaint() and EndPaint() to prevent infinite WM_PAINT messages.
			// But that seems to introduce some tearing/lag. If we instead just enter the default window proc, no drawing occurs.
			// The event gets handled and things seem smooth.
		case WM_SIZE;
			EnterCriticalSection(*renderThreadCriticalSection);
			mainWindowW = LOWORD(lParam);
			mainWindowH = HIWORD(lParam);
			renderFlags |= .windowSizeChanged;
			LeaveCriticalSection(*renderThreadCriticalSection);
			return 0;
		case WM_GETMINMAXINFO;
			tagMINMAXINFO :: struct {
				ptReserved: POINT;
				ptMaxSize: POINT;
				ptMaxPosition: POINT;
				ptMinTrackSize: POINT; // Minimum width (x) and height (y)
				ptMaxTrackSize: POINT;
			}
			
			minmax: *tagMINMAXINFO = cast(*tagMINMAXINFO) lParam;
			minmax.ptMinTrackSize = mainWindowMinimumSize;
			return 0;
		case WM_CLOSE;
			// The render thread assumes this window is active, so we need to, between frames, tell it to terminate.
			// Here, I've set up a safe way to do it with a flag, so the render thread can free its own resources or do whatever cleanup you want.
			EnterCriticalSection(*renderThreadCriticalSection);
			renderFlags |= .renderThreadShouldExit;
			WakeConditionVariable(*renderThreadWakeConditionVariable);
			LeaveCriticalSection(*renderThreadCriticalSection);
			DestroyWindow(hWnd);
			return 0;
		case WM_DESTROY;
			PostQuitMessage(0);
			return 0;
	}
	
	return DefWindowProcW(hWnd, message, wParam, lParam);
}

LOWORD :: (l: s64) -> s32 #no_context {
	return cast(s32) (l & 0xffff);
}

HIWORD :: (l: s64) -> s32 #no_context {
	return cast(s32) (l >> 16);
}

// A marginally-more static approach than the standard Jai version of this.
wide :: ($$utf8String: string) -> *u16 {
	#if is_constant(utf8String) && OS == .WINDOWS {
		count :: #run MultiByteToWideChar(CP_UTF8, 0, utf8String.data, cast(s32) utf8String.count,	null, 0) + 1;
	} else {
		count := MultiByteToWideChar(CP_UTF8, 0, utf8String.data, cast(s32) utf8String.count,	null, 0) + 1;
	}
	utf16String := cast(*u16) alloc((count) * size_of(u16)); // 2 extra bytes for zero termination WCHAR.
	MultiByteToWideChar(CP_UTF8, 0, utf8String.data, cast(s32) utf8String.count, utf16String, count);
	return utf16String;
}


PAINTSTRUCT :: struct {
	hdc: *void;          // HDC (handle to device context)
	fErase: s32;         // BOOL (32-bit boolean)
	rcPaint: RECT;       // RECT structure for paint region
	fRestore: s32;       // BOOL (32-bit boolean)
	fIncUpdate: s32;     // BOOL (32-bit boolean)
	rgbReserved: [32]u8; // BYTE array of 32 bytes
}

WaitMessage :: () -> s32 #foreign user32;
GetMessageW :: (lpMsg: *MSG, hWnd: *void, wMsgFilterMin: u32, wMsgFilterMax: u32) -> s32 #foreign user32;
DispatchMessageW :: (msg: *MSG) -> s32 #foreign user32;
BeginPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> *void #foreign user32;
EndPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> s32 #foreign user32;