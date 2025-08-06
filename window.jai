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
		hbrBackground = CreateSolidBrush(0);
		lpfnWndProc = DefWindowProcW; // The default windowproc handles WM_CLOSE, which is all we need for now to stay responsive.
		RegisterClassExW(*mainWindowClass);
	}
	mainContext = *context;
	mainWindow = CreateWindowExW(0, mainWindowClassName, wide("A great window"), WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, null, hInstance, null);
	UpdateWindow(mainWindow);
	
	GetClientRect(mainWindow, *reusableRECT);
	mainWindowW = reusableRECT.right - reusableRECT.left;
	mainWindowH = reusableRECT.bottom - reusableRECT.top;
}

mainWindowReceiveMessages :: () {
	while GetMessageW(*reusableMSG, null, 0, 0) {
		if reusableMSG.message == {
			case WM_QUIT;
				return;
			// TODO: Keyboard/mouse.
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


#scope_file

#import "Windows";

// If you need to call Jai-things in the windowProc, you'll need to push this first.
// It seems to be 100% safe in my extensive testing to do this.
// It's even done this way in the Odin WindowProc example. (Odin also has a context.)
// At the end of the day, we're sticking to one context per thread. Seems fine.
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
			
			// This is here to prevent redundant WM_PAINT messages. We don't actually draw here.
			BeginPaint(hWnd, *reusablePAINTSTRUCT);
			EndPaint(hWnd, *reusablePAINTSTRUCT);
			
			return 0;
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

user32 :: #system_library "user32";
WaitMessage :: () -> s32 #foreign user32;
GetMessageW :: (lpMsg: *MSG, hWnd: *void, wMsgFilterMin: u32, wMsgFilterMax: u32) -> s32 #foreign user32;
DispatchMessageW :: (msg: *MSG) -> s32 #foreign user32;
BeginPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> *void #foreign user32;
EndPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> s32 #foreign user32;