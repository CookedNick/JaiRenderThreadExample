Window :: struct {
	// The current w/h. Updated automatically by the windowProc.
	w, h: s32;
	
	// The minimum size of the window. You can adjust this directly, but the window will not be adjusted automatically nor will it grow if it's currently too small.
	// Call setMinimumSize(*Window, POINT) instead to automatically handle all of that.
	minimumSize: POINT;
	jaiContext: *#Context;
	
	// Render state for the window. Shared with the render thread.
	using shared: SharedRenderState;
}

setMinimumSize :: ($$window: *Window, $$new: POINT) {
	// If needed, resize the window to be at least the new minimum size.
	w, h := window.w, window.h;
	if w < new.x || h < new.y {
		w, h = max(w, new.x), max(h, new.y);
		window.w, window.h = w, h;
		nextFrame := *window.shared.nextFrame;
		threadSafeAccess(nextFrame, #code {
			nextFrame.value.windowW = xx w;
			nextFrame.value.windowH = xx h;
		});
		SetWindowPos(window.hWnd, null, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
	}
	
	// Adjust for the window's title bar.
	windowRECT := RECT.{0, 0, new.x, new.y};
	AdjustWindowRect(*windowRECT, WS_OVERLAPPEDWINDOW, .FALSE);
	
	// Set the minimum size. This gets reported to Windows in the windowProc during WM_GETMINMAXINFO.
	window.minimumSize = .{
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
	init(*window.shared);
	
	// Get its initial size.
	window.w, window.h = getWindowSize(window.hWnd);
	nextFrame := *window.shared.nextFrame.value;
	nextFrame.windowW = xx window.w;
	nextFrame.windowH = xx window.h;
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
						if !isRepeating(lParam) {
							// Pause/Resume animation
							
							// I know everyone likes performance counters (Basic.current_time_monotonic() uses one),
							// but the value of GetTickCount64() is that it will give you the exact same timestamp
							// in milliseconds as the keydown event (I'd get it directly, but the MSG version is only
							// 32-bit. But GetTickCount64() returns the exact same timestamp in 64-bit. So this is the
							// best way to align stuff to the moment of keydown. current_time_monotonic() will be a
							// more precise measurement (sub-ms), but it will be report a later time than the actual event.
							messageT := GetTickCount64();
							
							shared := *window.shared;
							nextFrame := *shared.nextFrame;
							
							threadSafeAccess(nextFrame, #code {
								if nextFrame.value.flags & .animatingDemo {
									// The animation is playing. Pause it.
									nextFrame.value.flags -= (.renderIndefinitely | .animatingDemo);
									
									// And let's update the animation up to the timestamp of this keypress.
									updateDemoAnimation(*nextFrame.value, messageT);
									
									// If the animation is playing, we can assume the render thread was active. So no need to wake.
								} else {
									// The animation is not playing. Start it.
									nextFrame.value.flags |= (.renderIndefinitely | .animatingDemo);
									
									// Resuming from the time of the keypress.
									nextFrame.value.demoAnimationLastUpdateT = messageT;
									
									// Wake the render thread if needed.
									signal(*shared.renderThreadShouldWakeUpIfSleeping);
								}
							});
							
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


// mainWindowUpdateSize :: () #no_context {
// }

windowProc :: (hWnd: *void, message: u32, wParam: u64, lParam: s64) -> s64 #c_call {
	window: *Window = xx GetWindowLongPtrW(hWnd, GWLP_USERDATA);
	
	push_context window.jaiContext {
		if message == {
			case WM_SIZE;
				window.w, window.h = LOWORD(lParam), HIWORD(lParam);
				
				shared := *window.shared;
				threadSafeAccess(*shared.nextFrame, #code {
					shared.nextFrame.value.windowW = xx window.w;
					shared.nextFrame.value.windowH = xx window.h;
					shared.nextFrame.value.flags |= .windowSizeHasChanged;
				});
				
				// We won't tell the render thread to wake up yet.
				// We'll do that in WM_PAINT, which gets sent to us next.
				
				return 0;
			case WM_PAINT;
				shared := *window.shared;
				BeginPaint(hWnd, null);
				signal(*shared.renderThreadShouldWakeUpIfSleeping);
				await(*shared.renderThreadFinishedAFrame);
				
				// Since we don't know when the GPU will actually display the frame (lol gpus),
				// we'll just sleep here to stop Windows from redrawing the window border for 2ms.
				// This one line is really responsible for the good resizing behavior.
				// If you remove this sleep, you'll get some artifacting, BUT Windows will poll
				// your mouse for resize movements more often while you're dragging the window border.
				// Meaning you can remove this to increase mouse-responsiveness at the cost of visual
				// artifacts when resizing (or occasionally when moving) your window.
				sleep_milliseconds(2);
				
				EndPaint(hWnd, null);
				return 0;
			case WM_GETMINMAXINFO;
				(cast(*MINMAXINFO) lParam).ptMinTrackSize = window.minimumSize;
				return 0;
			case WM_CLOSE; // The window is being closed.
				shared := *window.shared;
				
				// Tell the render thread to terminate.
				threadSafeAccess(*shared.flags, #code { shared.flags.value |= .renderThreadShouldTerminate; });
				
				// Only after we know the render thread has terminated, do we destroy the hWnd.
				signal(*shared.renderThreadShouldWakeUpIfSleeping);
				await(*shared.renderThreadTerminated);
				DestroyWindow(hWnd);
				return 0;
			case WM_DESTROY; // The hWnd was destroyed.
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