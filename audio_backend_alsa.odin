#+build linux
#+vet explicit-allocators
#+private file
package karl2d

@(private = "package")
AUDIO_BACKEND_ALSA :: Audio_Backend_Interface {
	state_size         = alsa_state_size,
	init               = alsa_init,
	shutdown           = alsa_shutdown,
	set_internal_state = alsa_set_internal_state,
	feed               = alsa_feed,
	remaining_samples  = alsa_remaining_samples,
}

import "base:runtime"
import "core:c"
import "log"
import alsa "platform_bindings/linux/alsa"
import "core:thread"
import "core:time"
import "core:sync"
import vmem "core:mem/virtual"
import "core:slice"

Alsa_State :: struct {
	pcm: alsa.PCM,
	samples: [dynamic]Audio_Sample,
	samples_mutex: sync.Mutex,
	samples_remaining: int,
	feed_thread: ^thread.Thread,
	run_thread: bool,
}

alsa_state_size :: proc() -> int {
	return size_of(Alsa_State)
}

s: ^Alsa_State

alsa_init :: proc(state: rawptr, allocator: runtime.Allocator) {
	assert(state != nil)
	s = (^Alsa_State)(state)
	log.debug("Init audio backend alsa")

	alsa_err: c.int
	pcm: alsa.PCM
	alsa_err = alsa.pcm_open(&pcm, "default", .PLAYBACK, 0)

	if alsa_err < 0 {
		log.errorf("pcm_open failed for 'default': %s", alsa.strerror(alsa_err))
		return
	}

	LATENCY_MICROSECONDS :: 25000
	alsa_err = alsa.pcm_set_params(
		pcm,
		.FLOAT_LE,
		.RW_INTERLEAVED,
		2,
		44100,
		1,
		LATENCY_MICROSECONDS,
	)

	if alsa_err < 0 {
		log.errorf("pcm_set_params failed: %s", alsa.strerror(alsa_err))
		alsa.pcm_close(pcm)
		return
	}

	alsa_err = alsa.pcm_prepare(pcm)

	if alsa_err < 0 {
		log.errorf("pcm_prepare failed: %s", alsa.strerror(alsa_err))
		alsa.pcm_close(pcm)
		return
	}

	s.run_thread = true
	s.feed_thread = thread.create(alsa_thread_proc)
	thread.start(s.feed_thread)
	s.pcm = pcm
}

alsa_thread_proc :: proc(t: ^thread.Thread) {
	arena: vmem.Arena
	arena_alloc := vmem.arena_allocator(&arena)

	for s.run_thread {
		time.sleep(5 * time.Millisecond)
		sync.lock(&s.samples_mutex)
		remaining := slice.clone(s.samples[:], arena_alloc)
		sync.atomic_sub(&s.samples_remaining, len(s.samples))
		runtime.clear(&s.samples)
		sync.unlock(&s.samples_mutex)

		for len(remaining) > 0 {
			// Note that this blocks. But this runs on a thread so that's fine.
			ret := alsa.pcm_writei(s.pcm, raw_data(remaining), c.ulong(len(remaining)))

			if ret < 0 {
				// Recover from errors. One possible error is an underrun. I.e. ALSA ran out of bytes.
				// In that case we must recover the PCM device and then try feeding it data again.
				recover_ret := alsa.pcm_recover(s.pcm, c.int(ret), 1)

				// Can't recover!
				if recover_ret < 0 {
					break
				}

				continue
			}

			written := int(ret)
			remaining = remaining[written:]
		}

		free_all(arena_alloc)
	}

	vmem.arena_destroy(&arena)
}

alsa_shutdown :: proc() {
	s.run_thread = false
	thread.join(s.feed_thread)

	log.debug("Shutdown audio backend alsa")
	if s.pcm != nil {
		alsa.pcm_close(s.pcm)
		s.pcm = nil
	}
}

alsa_set_internal_state :: proc(state: rawptr) {
	assert(state != nil)
	s = (^Alsa_State)(state)
}

alsa_feed :: proc(samples: []Audio_Sample) {
	if s.pcm == nil || len(samples) == 0 {
		return
	}
	
	sync.lock(&s.samples_mutex)
	append(&s.samples, ..samples)
	sync.atomic_add(&s.samples_remaining, len(samples))
	sync.unlock(&s.samples_mutex)
}

alsa_remaining_samples :: proc() -> int {
	if s.pcm == nil {
		return 0
	}
	return sync.atomic_load(&s.samples_remaining)
}
