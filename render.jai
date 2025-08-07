renderFlags: enum_flags u8 {
	// If this is set, rendering will continue (without sleeping!) until it's removed.
	// Use when playing animations.
	renderIndefinitely :: 1;
	
	// Use to ensure we draw at least one more frame.
	// The render thread resets this bit to 0 at the start of each frame automatically.
	renderAtLeastOneMoreFrame :: 1 << 1;
	
	// Use to recompute interface element sizes.
	windowSizeChanged :: 1 << 2;
	
	// Use to tell the render thread to clean up and end itself.
	renderThreadShouldExit :: 1 << 3;
	
	// Demonstration of an animation that will play even during window resizes/moves.
	animating :: 1 << 4;
	
	// This just means we're going negative instead of positive. Flips back and forth once per second.
	animatingInReverse :: 1 << 5;
} = .renderIndefinitely | .animating;

renderThreadCriticalSection: RTL_CRITICAL_SECTION;

animationLastUpdateT: u64;


initRenderThread :: () {
	InitializeCriticalSection(*renderThreadCriticalSection);
	InitializeConditionVariable(*renderThreadWakeConditionVariable);
	
// TODO: Figure out if we really need to do all this. Especially the temporary_storage bit.
	renderThreadContext.allocator = context.allocator;
	renderThreadContext.logger = context.logger;
	renderThreadContext.logger_data = context.logger_data;
	renderThreadContext.temporary_storage = *renderThreadTemporaryStorage;
	
	// The second `null` here can be replaced with a pointer to anything you want, and it will be available as the passed-in parameter in the thread procedure below.
	// For single-window programs, it is simpler to just use globals. Which is how we're accessing mainWindow.
	// For multiple-windows, you could do something like pass an hWnd to its own render thread, all managed in dynamic memory land.
	CreateThread(null, 0, xx enterRenderThread, null, 0, *renderThreadID);
}

renderThreadWakeConditionVariable: CONDITION_VARIABLE;


// t == current time.
updateBackgroundAnimation :: (t: u64) {
	// Get the difference in ms between this frame and the last update.
	diffThisFrame = t - animationLastUpdateT; // You could do a swap here and use one less var.
	animationLastUpdateT = t;
	
	if renderFlags & .animatingInReverse {
		animationProgress -= (cast(float)   diffThisFrame)/1000;
		
		if animationProgress <= 0 {
			// Wrap back around.
			animationProgress *= -1;
			renderFlags -= .animatingInReverse;
		}
	} else {
		animationProgress += (cast(float)   diffThisFrame)/1000;
		
		if animationProgress >= 1 {
			// Wrap back around.
			animationProgress -= (animationProgress - 1) * 2;
			renderFlags |= .animatingInReverse;
		}
	}
}


#scope_file

#import "Windows";
Simp :: #import "Simp";
GL :: #import "GL";

renderThreadID: s32 = 1;
renderThreadTemporaryStorage: Temporary_Storage;
renderThreadContext: #Context;


enterRenderThread :: (_: *void) -> u32 #c_call {
	push_context renderThreadContext {
		// At this time, the main window is not receiving messages yet, so we can presume safe data access without invoking the critical section.
		// But that's not such a big deal perf-wise, so feel free to do it here for peace of mind if you like.
		
		// Here, you can do something like Simp.set_render_target(mainWindow).
		// Or, if doing something more manual, CreateCompatibleDC or GetDC.
		// Simp in particular does not work across multiple threads.
		// Most rendering APIs don't. (Do any?)
		// So here is where you'd init that sort of thing. Not on the main thread.
		// For now, it's just the skeleton. But try it. It will work.
		Simp.set_render_target(mainWindow);
		Simp.set_shader_for_color(true);
		
		// Enable vsync.
		GL.wglSwapIntervalEXT(1);
		
		// Now that we're ready for rendering, show the window.
		// The reason we wait this long is to have the shortest possible time with blank contents.
		ShowWindow(mainWindow, SW_SHOW);
		
		// Start the animation.
		animationLastUpdateT = GetTickCount64();
		
		// Render the first frame.
		renderAFrame();
		
		// Activate the real window proc.
		mainWindowActivateWindowProc();
		
		// We're now officially rendering and responsive to user input. The program is fully live.
		
		while true {
			// We live in this critical section by default to prevent data races.
			// You can enter/leave this in any thread to modify data that also gets touched by the render thread.
			// For example, player position in a game or inputted chars in a text editor.
			// You can also use Jai's Mutex type for this (modules/Thread). Under the hood on Windows, that type uses these critical sections.
			// I just don't personally need all the extra stuff the Jai version does. But, Mutex is cross-platform. That's something.
			EnterCriticalSection(*renderThreadCriticalSection);
			
			// Exit the loop if we're terminating.
			if renderFlags & .renderThreadShouldExit break;
			
			// If another thread wants us to keep rendering, we'll keep rendering.
			if !(renderFlags & (.renderAtLeastOneMoreFrame | .renderIndefinitely)) {
				// If we're here, we don't need to render anything.
				// Put the thread to sleep and wait for a signal to resume rendering.
				SleepConditionVariableCS(*renderThreadWakeConditionVariable, *renderThreadCriticalSection, WIN_TIMEOUT_INFINITE);
			}
			
			// Clear this flag since we're about to render.
			renderFlags &= ~.renderAtLeastOneMoreFrame;
			renderAFrame();
			LeaveCriticalSection(*renderThreadCriticalSection);
			// Here is where other threads have a chance to modify data.
			reset_temporary_storage();
			
			// Prevents a ton of lag and thread-fighting when rendering indefinitely.
			sleep_milliseconds(1);
		}
	
		// Clean up if needed.
		LeaveCriticalSection(*renderThreadCriticalSection);
		print("The render thread is exiting.\n");
	}
	
	return 0;
}


// Animation vars
t: u64;
diffThisFrame: u64;
animationProgress: float; // 0-1


// Assumes we are in the critical section. It's safe to touch data.
// You might want to only enter the critical section when actually accessing the data.
// This allows other threads more chances to get their work done on it.
// The only caveat is you don't want to have this desynced.
// For example, if a keypress swaps dark mode mid-frame, you might have half the elements dark and half of them light.
// So you want to only enter the critical section once per frame. That will prevent this issue.
renderAFrame :: () {
	// Check if we need to resize interface elements.
	if renderFlags & .windowSizeChanged {
		renderFlags -= .windowSizeChanged;
		Simp.update_window(mainWindow);
		// TODO: Resize interface elements.
		
		// TEMP: Just demonstrating that it works.
		print("New Window Size: w=%, h=%\n", mainWindowW, mainWindowH);
	}
	
	if renderFlags & .animating {
		// This is a little imperfect. We should be updating it to the estimated time of the swap_buffers call below,
		// not "now" just as we need the data. See https://www.youtube.com/watch?v=yGhfUcPjXuE for a masterclass on deltaTime.
		updateBackgroundAnimation(GetTickCount64());
	}

	// Background. Don't clear the render target! It causes flashing during resizes. Instead, just draw over the whole window.
	Simp.immediate_quad(0, 0, (cast(float) mainWindowW), (cast(float) mainWindowH), .{animationProgress, animationProgress, animationProgress, 1});
	
	// Red, green, and blue squares.
	Simp.immediate_quad(50, 50, ((cast(float) mainWindowW)/3) - 25, ((cast(float) mainWindowH)/3) - 50, .{1, 0, 0, 1 - animationProgress/4});
	Simp.immediate_quad(((cast(float) mainWindowW)/3) + 25, 50, ((cast(float) mainWindowW)*2/3) - 25, ((cast(float) mainWindowH)/3) - 50, .{0, 1, 0, 1 - animationProgress/4});
	Simp.immediate_quad(((cast(float) mainWindowW)*2/3) + 25, 50, (cast(float) mainWindowW) - 50, ((cast(float) mainWindowH)/3) - 50, .{0, 0, 1, 1 - animationProgress/4});
	
	Simp.swap_buffers(mainWindow);
}
