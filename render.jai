demoQuadLength : float : 100;

// All the data that is shared between the render thread and the main thread for a given window.
// Enter the appropriate critical section when modifying or reading a var. Then leave it ASAP
// or else you'll lock frequently. Critical sections indicate to the kernel that "only my thread
// should be allowed to touch this thing at this time", saving you from access violation crashes.
// For example, if the main thread tries to enter a section that the render thread is currently
// within, the kernel will put it to sleep until the render thread has left the section, ensuring
// safe access and minimal CPU usage.
SharedRenderState :: struct {
	// General flags for communication.
	flags: ThreadSafe(
		enum_flags u8 {
			// Tell the render thread that it should go crawl in a hole and die.
			renderThreadShouldTerminate :: 1;
		}
	);
	
	// The window we are rendering to. If you're wondering why it's not ThreadSafe(*void), we only
	// need to do that if the value will be modified later. For values that never change, this is safe.
	hWnd: *void;
	
	// The data for the next frame to be drawn.
	nextFrame: ThreadSafe(FrameData) = .{ value = .{ flags = (.renderIndefinitely | .animatingDemo) } };
	
	// Awaitable moments for syncing. ("Sleep until thing X happens on another thread.")
	renderThreadShouldWakeUpIfSleeping: Awaitable;
	renderThreadFinishedAFrame: Awaitable;
	renderThreadTerminated: Awaitable;
}

init :: (using srs: *SharedRenderState) {
	init(*flags);
	init(*nextFrame);
	init(*renderThreadShouldWakeUpIfSleeping);
	init(*renderThreadFinishedAFrame);
	init(*renderThreadTerminated);
}

deinit :: (using srs: *SharedRenderState) {
	deinit(*flags);
	deinit(*nextFrame);
	deinit(*renderThreadShouldWakeUpIfSleeping);
	deinit(*renderThreadFinishedAFrame);
	deinit(*renderThreadTerminated);
}

// The data needed to draw a frame.
FrameData :: struct {
	flags: Flags;
	windowW, windowH: float;
	demoAnimationProgress: float; // 0-1
	demoAnimationLastUpdateT: u64;
	
	Flags :: enum_flags u8 {
		// If this is set, the render thread will continue drawing frames without sleeping.
		// Use when playing animations.
		renderIndefinitely :: 1;
		
		// The window size has changed.
		windowSizeHasChanged :: 1 << 1;
		
		// DEMO: our animation isn't paused. Keep updating it each frame.
		animatingDemo :: 1 << 2;
			
		// DEMO: This just means we're going negative instead of positive. Flips back and forth once per second.
		animatingDemoInReverse :: 1 << 3;
	}
}

/* ThreadSafe is a primitive for saying "This variable should only ever be accessed from one thread at a time."
   To read/write the value safely, use the `threadSafeAccess()` macro. During the execution of the macro, you will be
   within the critical section.
   
   Example:
   	
   	someVar := ThreadSafe(int).{ value = 1 };
   	init(*someVar); // Required.
   	threadSafeAccess(*someVar, #code {
   		print("value is %.\n", value); // get
   		value = 2;                     // set
   		print("value is %.\n", value); // get
   	});
   	deinit(*someVar); // When you're completely done with someVar.
*/
ThreadSafe :: struct(Value: Type) {
	// Don't access directly. Instead, use the threadSafe macro.
	value: Value;
	criticalSection: RTL_CRITICAL_SECTION;
}

init :: (ts: *ThreadSafe($T)) {
	InitializeCriticalSection(*ts.criticalSection);
}

deinit :: (ts: *ThreadSafe($T)) {
	DeleteCriticalSection(*ts.criticalSection);
}

// Within this block, other threads won't be able to touch this value.
// If they try, they will sleep until you exit this block here.
threadSafeAccess :: (ts: *ThreadSafe($T), action: Code) #expand {
	EnterCriticalSection(*ts.criticalSection);
	#insert action;
	LeaveCriticalSection(*ts.criticalSection);
}

// This will return a thread-local copy of a ThreadSafe value.
threadSafeCopy :: (using ts: *ThreadSafe($T)) -> T {
	EnterCriticalSection(*criticalSection);
	copy := value;
	LeaveCriticalSection(*criticalSection);
	return copy;
}


// A primitive to say "Let's sleep until another thread wakes us up." Make sure in advance that
// you actually are going to be woken up. (Ensure the other thread is awake, etc.)
Awaitable :: struct {
	using ts: ThreadSafe(Data);
	Data :: struct {
		conditionVariable: CONDITION_VARIABLE;
		threadsCurrentlySleeping: int;
	}
}

init :: (using awaitable: *Awaitable) {
	init(*ts);
	InitializeConditionVariable(*value.conditionVariable);
}

deinit :: inline (using awaitable: *Awaitable) {
	deinit(*ts);
}

// Go to sleep until woken up by another thread.
await :: (using awaitable: *Awaitable) {
	threadSafeAccess(*ts, #code {
		value.threadsCurrentlySleeping += 1;
		SleepConditionVariableCS(*value.conditionVariable, *criticalSection, WIN_TIMEOUT_INFINITE);
		value.threadsCurrentlySleeping -= 1;
	});
}

// Signal another thread to wake up if it's sleeping.
signal :: (using awaitable: *Awaitable) -> aThreadWasWokenUp: bool {
	aThreadWasWokenUp: bool = ---;
	threadSafeAccess(*ts, #code {
		aThreadWasWokenUp = xx value.threadsCurrentlySleeping;
		WakeConditionVariable(*value.conditionVariable);
	});
	return aThreadWasWokenUp;
}


startRenderThread :: (window: *Window) {
	// Generate a new Jai Context for the thread.
	// TODO: Figure out if we really need to do all this. Especially the temporary_storage bit.
	renderThreadContext.allocator = context.allocator;
	renderThreadContext.logger = context.logger;
	renderThreadContext.logger_data = context.logger_data;
	renderThreadContext.temporary_storage = New(Temporary_Storage);
	
	CreateThread(null, 0, xx enterRenderThread, *window.shared, 0, null);
}

// t == current time.
updateDemoAnimation :: (using thisFrame: *FrameData, t: u64) {
	// // Get the difference in ms between this frame and the last update.
	diffThisFrame := t - demoAnimationLastUpdateT; // PERF: You could do a swap here and use one less var.
	demoAnimationLastUpdateT = t;
	
	// PERF: There is for-sure a branchless way to approach this.
	if flags & .animatingDemoInReverse {
		demoAnimationProgress -= (cast(float) diffThisFrame)/1000;
		
		if demoAnimationProgress <= 0 {
			// Wrap back around.
			demoAnimationProgress *= -1;
			flags -= .animatingDemoInReverse;
		}
	} else {
		demoAnimationProgress += (cast(float) diffThisFrame)/1000;
		
		if demoAnimationProgress >= 1 {
			// Wrap back around.
			demoAnimationProgress -= (demoAnimationProgress - 1) * 2;
			flags |= .animatingDemoInReverse;
		}
	}
}


#scope_file

#import "Windows";
Simp :: #import "Simp";
GL :: #import "GL";

renderThreadTemporaryStorage: Temporary_Storage;
renderThreadContext: #Context;


enterRenderThread :: (using shared: *SharedRenderState) -> u32 #c_call {
	push_context renderThreadContext {
		// Simp in particular does not work across multiple threads.
		// Most rendering APIs don't. (Do any?)
		// So here is where you'd init that sort of thing. In the same thread where we'll render.
		// No Simp stuff ever gets called from other threads, only this one.
		// You could modify Simp to support that, if you wanted, but this example will remain minimal.
		Simp.set_render_target(hWnd);
		Simp.set_shader_for_color(false);
		
		// Disable vsync. Up to you. Our smooth resizes work either way.
		GL.wglSwapIntervalEXT(0);
		
		// Start the animation.
		threadSafeAccess(*shared.nextFrame, #code { shared.nextFrame.value.demoAnimationLastUpdateT = GetTickCount64(); });
		
		while true {
			// Check if we should terminate.
			renderFlags := threadSafeCopy(*shared.flags);
			if renderFlags & .renderThreadShouldTerminate break;
			
			// Get the data for the current frame.
			using thisFrame: FrameData = ---;
			thisFrameFlags: FrameData.Flags = ---;
			threadSafeAccess(*shared.nextFrame, #code {
				thisFrame = shared.nextFrame.value;
				
				// Store a copy of the flags we got before we can modify them.
				thisFrameFlags = thisFrame.flags;
			
				// Check if the window size has changed.
				if flags & .windowSizeHasChanged {
					flags -= .windowSizeHasChanged;
					Simp.update_window(hWnd);
				}
				
				if flags & .animatingDemo
					updateDemoAnimation(*thisFrame, GetTickCount64());
				
				// Keep our changes for the next frame.
				shared.nextFrame.value = thisFrame;
			});
			
			// Demo: White/Black background.
			Simp.immediate_quad(0, 0, windowW, windowH, .{1 - demoAnimationProgress, 1 - demoAnimationProgress, 1 - demoAnimationProgress, 1});
			
			// Demo: Some calculated state for our quads. You could store these in FrameData and only recalculate them during WM_SIZE (or when
			// we receive the .windowSizeHasChanged flag) if desired.
			
			// Demo: Red/Cyan quad.
			Simp.immediate_quad(
				x0 = demoAnimationProgress * (windowW - demoQuadLength),
				y0 = windowH*2/3,
				x1 = demoAnimationProgress * (windowW - demoQuadLength) + demoQuadLength,
				y1 = windowH,
				color = .{1 - demoAnimationProgress, demoAnimationProgress, demoAnimationProgress, 1}
			);
			
			// Demo: Green/Magenta quad.
			Simp.immediate_quad(
				x0 = (1 - demoAnimationProgress) * (windowW - demoQuadLength),
				y0 = windowH/3,
				x1 = (1 - demoAnimationProgress) * (windowW - demoQuadLength) + demoQuadLength,
				y1 = windowH*2/3,
				color = .{demoAnimationProgress, 1 - demoAnimationProgress, demoAnimationProgress, 1}
			);
			
			// Demo: Blue/Yellow quad.
			Simp.immediate_quad(
				x0 = demoAnimationProgress * (windowW - demoQuadLength),
				y0 = 0,
				x1 = demoAnimationProgress * (windowW - demoQuadLength) + demoQuadLength,
				y1 = windowH/3,
				color = .{demoAnimationProgress, demoAnimationProgress, 1 - demoAnimationProgress, 1}
			);
			
			// Update the window.
			Simp.swap_buffers(hWnd);
			
			// Tell other threads we finished drawing a frame. WM_PAINT waits for this signal before returning.
			signal(*shared.renderThreadFinishedAFrame);
			
			// Frame-local cleanup.
			reset_temporary_storage();
			
			// If we're not rendering indefinitely, sleep.
			if !(flags & .renderIndefinitely) {
				// Do some final checks before we actually sleep. Maybe these values were changed from another thread since the start of the frame.
				
				// Check if the next frame wants us to keep rendering. If so, we won't sleep.
				nextFrameFlags: FrameData.Flags = ---;
				threadSafeAccess(*shared.nextFrame, #code { nextFrameFlags = shared.nextFrame.value.flags; });
				
				// Check again real quick if we should terminate. We don't want to miss this when we sleep.
				renderFlags = threadSafeCopy(*shared.flags);
				if renderFlags & .renderThreadShouldTerminate break;
				
				if !(nextFrameFlags & .renderIndefinitely)
					await(*shared.renderThreadShouldWakeUpIfSleeping);
			}
		}
	
		// Clean up.
		allocator := context.allocator;
		allocator.proc(.THREAD_STOP, 0, 0, null, allocator.data);
		signal(*shared.renderThreadTerminated);
		return 0;
	}
}