Window :: struct {
	hWnd: *void;
	
	// The current w/h. Updated automatically by the windowProc.
	w, h: s32;
	
	// The minimum size of the window. You can adjust this directly, but the window will not be adjusted
	// automatically nor will it grow if it's currently too small. Call setMinimumSize(*Window, POINT)
	// instead to automatically handle all of that.
	minSize: POINT;
	
	// Our lock between the threads.
	criticalSection: CRITICAL_SECTION;
	
	// Our condition to wake a sleeping thread.
	conditionVariable: CONDITION_VARIABLE;
	
	jaiContext: *#Context;
	
	nextFrame: FrameInfo;
	
	FrameInfo :: struct {
		// Synced by the windowProc with window.w, window.h.
		w, h: float;
		
		// The time of an event. Like resuming/pausing the animation.
		eventT: Apollo_Time;
		
		flags: enum_flags u8 {
			windowSizeHasChanged :: 1;
			terminateRenderThread :: 1 << 1;
			toggleDemoAnimationPlayback :: 1 << 2;
			skipToThisFrame :: 1 << 3;
		} = .skipToThisFrame;
	};
}


setMinimumSize :: (window: *Window, new: POINT) {
	// If needed, resize the window to be at least the new minimum size.
	w, h := window.w, window.h;
	if w < new.x || h < new.y {
		w, h = max(w, new.x), max(h, new.y);
		window.w, window.h = w, h;
		EnterCriticalSection(*window.criticalSection);
		window.nextFrame.w = xx w;
		window.nextFrame.h = xx h;
		
		window.nextFrame.flags |= (.windowSizeHasChanged | .skipToThisFrame);

		// Wake up the render thread if it's sleeping.
		WakeConditionVariable(*window.conditionVariable);
		
		LeaveCriticalSection(*window.criticalSection);
		SetWindowPos(window.hWnd, null, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
	}
	
	// Adjust for the window's title bar.
	windowRECT := RECT.{0, 0, new.x, new.y};
	AdjustWindowRect(*windowRECT, WS_OVERLAPPEDWINDOW, .FALSE);
	
	// Set the minimum size. This gets reported to Windows in the windowProc during WM_GETMINMAXINFO.
	window.minSize = .{
		windowRECT.right - windowRECT.left,
		windowRECT.bottom - windowRECT.top
	};
}

createAndShowWindow :: ($$title: string, x: s32 = CW_USEDEFAULT, y: s32 = CW_USEDEFAULT, w: s32 = CW_USEDEFAULT, h: s32 = CW_USEDEFAULT) -> *Window {
	// Get our Windows module handle.
	hInstance := GetModuleHandleW(null);
	
	// Set up the window class.
	windowClass := WNDCLASSEXW.{
		cbSize = size_of(WNDCLASSEXW),
		style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC, // The first two flags together say: "WM_SIZE should trigger WM_PAINT."
		hInstance = hInstance,
		hCursor = LoadCursorW(null, IDC_ARROW),
		lpszClassName = wide("ResponsiveRenderingWindow"),
		hbrBackground = null, // No background since we're replacing the window's entire contents every frame ourselves.
		lpfnWndProc = DefWindowProcW
	};
	RegisterClassExW(*windowClass);
	
	// Adjust the passed w/h to include the title bar.
	adjustedW, adjustedH := w, h;
	if w != CW_USEDEFAULT || h != CW_USEDEFAULT {
		windowRECT := RECT.{0, 0, w, h};
		AdjustWindowRect(*windowRECT, WS_OVERLAPPEDWINDOW, .FALSE);
		
		if w != CW_USEDEFAULT
			adjustedW = windowRECT.right - windowRECT.left;
		
		if h != CW_USEDEFAULT
			adjustedH = windowRECT.bottom - windowRECT.top;
	}
	
	// Make our window.
	window := New(Window, initialized = false);
	window.* = .{
		jaiContext = *context,
		hWnd = CreateWindowExW(0, windowClass.lpszClassName, wide(title), WS_OVERLAPPEDWINDOW, x, y, adjustedW, adjustedH, null, null, hInstance, null)
	};
	InitializeCriticalSection(*window.criticalSection);
	InitializeConditionVariable(*window.conditionVariable);
	
	// Get its initial size.
	window.w, window.h = getWindowSize(window.hWnd);
	window.nextFrame.w = xx window.w;
	window.nextFrame.h = xx window.h;
	UpdateWindow(window.hWnd);
	ShowWindow(window.hWnd, SW_SHOW);
	
	// Attach our Window data to the hWnd so we can access it from the windowProc.
	SetWindowLongPtrW(window.hWnd, GWLP_USERDATA, xx window);
	
	// Now that our data is accessible, we can start using our actual windowProc.
	SetWindowLongPtrW(window.hWnd, GWLP_WNDPROC, cast(s64) cast(*void) windowProc);
	
	return window;
}

getWindowSize :: ($$hWnd: *void) -> w: s32, h: s32 {
	// Get the size.
	windowRECT: RECT;
	GetClientRect(hWnd, *windowRECT);
	return
		windowRECT.right - windowRECT.left,
		windowRECT.bottom - windowRECT.top;
}

handleAllRemainingMessages :: (using window: *Window) -> quit: bool {
	currentMSG: MSG = ---;
	
	while PeekMessageW(*currentMSG, null, 0, 0, PM_REMOVE) {
		// Tells us whether a key press is a repeating press using lParam.
		isRepeating :: (lParam: s64) -> bool {
			return cast(bool) ((lParam & (1 << 30)) >> 30);
		}
		
		// Tells us whether a key is pressed in general. For modifiers, this will be true if either the left or right
		// modifier key is pressed. False if neither are pressed.
		isPressed :: (key: s32) -> bool {
			return cast(bool) (GetKeyState(key) & 0b100000000000000);
		}
		
		using currentMSG;
		
		if message == {
			case WM_QUIT;
				return true;
			case WM_KEYDOWN;
				if wParam == {
					case #char " "; // Spacebar. Pause/resume the demo animation.
						eventT := current_time_monotonic();
						
						if !isRepeating(lParam) {
							// Pause/Resume animation
							EnterCriticalSection(*window.criticalSection);
							window.nextFrame.eventT = eventT;
							window.nextFrame.flags |= (.toggleDemoAnimationPlayback | .skipToThisFrame);
							
							// Wake up the render thread if it's sleeping.
							WakeConditionVariable(*window.conditionVariable);
							
							LeaveCriticalSection(*window.criticalSection);
							
							continue;
						}
				}
		}
		
		TranslateMessage(*currentMSG);
		DispatchMessageW(*currentMSG);
	}
	
	return false;
}

// Sleep until Windows gives us a message.
WaitMessage :: () -> s32 #foreign user32;

// System timestamp in ms. More aligned with "right now" than performance counters. But less precise. (ms instead of ns or whatever)
GetTickCount64 :: () -> u64 #foreign kernel32;


#scope_file

#import "Windows";
user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";

GWLP_WNDPROC :: -4;
GWLP_USERDATA :: -21;

WM_ENTERSIZEMOVE :: 561;
WM_EXITSIZEMOVE :: 562;

windowProc :: (hWnd: *void, message: u32, wParam: u64, lParam: s64) -> s64 #c_call {
	window: *Window = xx GetWindowLongPtrW(hWnd, GWLP_USERDATA);
	
	push_context window.jaiContext {
		if message == {
			case WM_SIZE;
				window.w, window.h = LOWORD(lParam), HIWORD(lParam);
				
				// We won't tell the render thread to wake up yet.
				// We'll do that in WM_PAINT, which gets sent to us next.
				
				return 0;
			case WM_PAINT;
				BeginPaint(hWnd, null);
				EnterCriticalSection(*window.criticalSection);
				
				if window.nextFrame.w != xx window.w || window.nextFrame.h != xx window.h {
					window.nextFrame.w, window.nextFrame.h = xx window.w, xx window.h;
					window.nextFrame.flags |= (.windowSizeHasChanged | .skipToThisFrame);
				} else {
					window.nextFrame.flags |= .skipToThisFrame;
				}
				
				// Wake up the render thread if it's sleeping.
				WakeConditionVariable(*window.conditionVariable);
				
				// Go to sleep ourselves until we're woken up once the frame is done.
				SleepConditionVariableCS(*window.conditionVariable, *window.criticalSection, WIN_TIMEOUT_INFINITE);
				
				LeaveCriticalSection(*window.criticalSection);
				EndPaint(hWnd, null);
				return 0;
			case WM_GETMINMAXINFO;
				(cast(*MINMAXINFO) lParam).ptMinTrackSize = window.minSize;
				return 0;
			case WM_CLOSE; // The window is being closed.
				EnterCriticalSection(*window.criticalSection);
				
				// Tell the render thread to terminate.
				window.nextFrame.flags |= .terminateRenderThread | .skipToThisFrame;
				
				// Wake the render thread if it's sleeping.
				WakeConditionVariable(*window.conditionVariable);
				
				// Go to sleep until the render thread has cleaned up. You can remove this line and it's mostly fine if you're just rushing to close.
				SleepConditionVariableCS(*window.conditionVariable, *window.criticalSection, WIN_TIMEOUT_INFINITE);
				
				LeaveCriticalSection(*window.criticalSection);
				
				// Only after we know the render thread has terminated do we destroy the hWnd.
				DestroyWindow(hWnd);
				return 0;
			case WM_DESTROY; // The hWnd was destroyed.
				// Clean up.
				DeleteCriticalSection(*window.criticalSection);
				
				// Send WM_QUIT to our main thread.
				PostQuitMessage(0);
				
				return 0;
		}
		
		return DefWindowProcW(hWnd, message, wParam, lParam);
	}
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

MINMAXINFO :: struct {
	ptReserved: POINT;
	ptMaxSize: POINT;
	ptMaxPosition: POINT;
	ptMinTrackSize: POINT; // Minimum width (x) and height (y)
	ptMaxTrackSize: POINT;
}

GetMessageW :: (lpMsg: *MSG, hWnd: *void, wMsgFilterMin: u32, wMsgFilterMax: u32) -> s32 #foreign user32;
DispatchMessageW :: (msg: *MSG) -> s32 #foreign user32;
BeginPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> *void #foreign user32;
EndPaint :: (hWnd: *void, lpPaint: *PAINTSTRUCT) -> s32 #foreign user32;
GetWindowLongPtrW :: (hWnd: *void, nIndex: s32) -> s64 #foreign user32;