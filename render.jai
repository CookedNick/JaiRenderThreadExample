demoQuadLength : float : 100;


startRenderThread :: (window: *Window) {
	// Generate a new Jai Context for the thread.
	// TODO: Figure out if we really need to do all this. Especially the temporary_storage bit.
	renderThreadContext.allocator = context.allocator;
	renderThreadContext.logger = context.logger;
	renderThreadContext.logger_data = context.logger_data;
	renderThreadContext.temporary_storage = New(Temporary_Storage);
	
	CreateThread(null, 0, xx enterRenderThread, window, 0, null);
}


#scope_file

#import "Windows";
Simp :: #import "Simp";
#import "GL";

renderThreadTemporaryStorage: Temporary_Storage;
renderThreadContext: #Context;


DemoAnimation :: struct {
	lastUpdateT: Apollo_Time;
	progress: float;
	
	flags: enum u8 {
		isRunning :: 1;
		isProgressingBackwards :: 1 << 1;
	};
}
	
update :: (using da: *DemoAnimation, t: Apollo_Time) {
	// Get the difference in ms between this frame and the last update.
	progressDiffThisFrame := cast(float) to_nanoseconds(t - lastUpdateT)/1_000_000_000; // PERF: You could do a swap here and use one less var.
	lastUpdateT = t;
	
	// PERF: There is for-sure a branchless way to approach this.
	if flags & .isProgressingBackwards {
		progress -= progressDiffThisFrame;
		
		if progress <= 0 {
			// Wrap back around.
			progress *= -1;
			flags -= .isProgressingBackwards;
		}
	} else {
		progress += progressDiffThisFrame;
		
		if progress >= 1 {
			// Wrap back around.
			progress -= (progress - 1) * 2;
			flags |= .isProgressingBackwards;
		}
	}
}

enterRenderThread :: (window: *Window) -> u32 #c_call {
	push_context renderThreadContext {
		// Simp in particular does not work across multiple threads.
		// Most rendering APIs don't. (Do any?)
		// So here is where you'd init that sort of thing. In the same thread where we'll render.
		// No Simp stuff ever gets called from other threads, only this one.
		// You could modify Simp to support that, if you wanted, but this example will remain minimal.
		Simp.set_render_target(window.hWnd);
		Simp.set_shader_for_color(false);
		
		// Enable vsync. Up to you. I recommend uncommenting the sleep_milliseconds(1) call below if you disable it.
		wglSwapIntervalEXT(1);
		
		demoAnimation: DemoAnimation;
		thisFrame: Window.FrameInfo;
		previousDrawT: Apollo_Time = current_time_monotonic();
		previousDeltaT: Apollo_Time;
		estimatedNextDrawT: Apollo_Time;
		dc: *void;
		fence: GLsync = ---;
		
		// WakeConditionVariable(*window.conditionVariable);
		
		while true {
			// Synchronize the threads.
			EnterCriticalSection(*window.criticalSection);
			
			// If both of these are true, we don't need to render a frame.
			// 	Condition 1: The next frame doesn't have any flags set.
			// 	Condition 2: We aren't animating.
			// Sleep until woken up.
			if !(demoAnimation.flags & .isRunning) && !window.nextFrame.flags {
				beforeSleepT := current_time_monotonic();
				SleepConditionVariableCS(*window.conditionVariable, *window.criticalSection, WIN_TIMEOUT_INFINITE);
				sleepDiff := current_time_monotonic() - beforeSleepT;
				
				// Adjust time so it's like the sleep never occurred.
				previousDrawT += sleepDiff;
			}
			
			// This frame's info.
			thisFrame = window.nextFrame;
			
			// Terminate if requested.
			if thisFrame.flags & .terminateRenderThread {
				LeaveCriticalSection(*window.criticalSection);
				break;
			}
			
			// Clear single-frame flags for next frame.
			window.nextFrame.flags = 0;
			
			LeaveCriticalSection(*window.criticalSection);
			
			estimatedNextDrawT = previousDrawT + previousDeltaT;
			
			if thisFrame.flags & .windowSizeHasChanged {
				Simp.update_window(window.hWnd);
			}
			
			if thisFrame.flags & .toggleDemoAnimationPlayback {
				if demoAnimation.flags & .isRunning {
					// Stop playback.
					demoAnimation.flags -= .isRunning;
					
					// Update the animation up to the time of the keypress.
					update(*demoAnimation, thisFrame.eventT);
				} else {
					// Resume playback.
					demoAnimation.flags |= .isRunning;
					
					// We resume from the the time of the keypress.
					demoAnimation.lastUpdateT = thisFrame.eventT;
					update(*demoAnimation, estimatedNextDrawT);
				}
			} else {
				if demoAnimation.flags & .isRunning
					update(*demoAnimation, estimatedNextDrawT);
			}
			
			// Demo: White/Black background.
			Simp.immediate_quad(0, 0, thisFrame.w, thisFrame.h, .{1 - demoAnimation.progress, 1 - demoAnimation.progress, 1 - demoAnimation.progress, 1});
			
			// Demo: Red/Cyan quad.
			Simp.immediate_quad(
				x0 = demoAnimation.progress * (thisFrame.w - demoQuadLength),
				y0 = thisFrame.h*2/3,
				x1 = demoAnimation.progress * (thisFrame.w - demoQuadLength) + demoQuadLength,
				y1 = thisFrame.h,
				color = .{1 - demoAnimation.progress, demoAnimation.progress, demoAnimation.progress, 1}
			);
			
			// Demo: Green/Magenta quad.
			Simp.immediate_quad(
				x0 = (1 - demoAnimation.progress) * (thisFrame.w - demoQuadLength),
				y0 = thisFrame.h/3,
				x1 = (1 - demoAnimation.progress) * (thisFrame.w - demoQuadLength) + demoQuadLength,
				y1 = thisFrame.h*2/3,
				color = .{demoAnimation.progress, 1 - demoAnimation.progress, demoAnimation.progress, 1}
			);
			
			// Demo: Blue/Yellow quad.
			Simp.immediate_quad(
				x0 = demoAnimation.progress * (thisFrame.w - demoQuadLength),
				y0 = 0,
				x1 = demoAnimation.progress * (thisFrame.w - demoQuadLength) + demoQuadLength,
				y1 = thisFrame.h/3,
				color = .{demoAnimation.progress, demoAnimation.progress, 1 - demoAnimation.progress, 1}
			);
			
			// Update the window. I would call Simp.swap_buffers here, but it doesn't call ReleaseDC, causing a leak and a really bad buildup of CPU usage over time.
			Simp.immediate_flush();
			dc := GetDC(window.hWnd);
			SwapBuffers(dc);
			ReleaseDC(window, dc);
			
			// If vsync is enabled, this sleep just gets in our way.
			// If vsync is disabled, you should use this. It will cut CPU usage down a ton and help stave off Windows wanting to slow-down busy threads.
			// sleep_milliseconds(1);
			
			// Just make sure the GPU really finished all the commands. This is good for properly syncing things to when the user actually sees them. Also helps to not
			// overload the GPU with work it can't handle. Which is also a waste for us here on the CPU.
			fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
			if fence {
			    glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000);
			    glDeleteSync(fence);
			}
			
			// Inform the next frame how long it took to draw this one.
			now := current_time_monotonic();
			previousDeltaT = now - previousDrawT;
			previousDrawT = now;
			
			// Wake the main thread if we finished the frame it wanted us to draw.
			if thisFrame.flags & .wakeMainThreadWhenCompleted
				WakeConditionVariable(*window.conditionVariable);
			
			// Frame-local cleanup.
			reset_temporary_storage();
		}
	
		// Clean up.
		allocator := context.allocator;
		allocator.proc(.THREAD_STOP, 0, 0, null, allocator.data);
		
		// Report that we finished terminating.
		WakeConditionVariable(*window.conditionVariable);
		
		return 0;
	}
}