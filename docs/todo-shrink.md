# TODO: shrink the resident footprint

`WWIVFOSS -L` currently stays resident at **37 KB**. BNU keeps about 5 KB of
code resident plus its buffers; X00 is in the same range. A DOS BBS that
loads the FOSSIL once and then runs doors under it feels every kilobyte, so
the target is **about 2.5 KB plus buffers (6.5 KB with the default 2 KB +
2 KB)**, and **0 KB of conventional memory** when upper memory is available.

## Where the 37 KB goes today

`load_resident()` calls `_dos_keep()` with the size of the whole memory
block the Open Watcom runtime set up, so everything stays: startup code, the
C library, option parsing, `printf`, the spawn code, the stack and the near
heap.

From `dos/wwivfoss.map` and `wdis` on each object, measured at commit
`0f32c8f`:

| Piece | Bytes | Needed resident? |
|---|---:|---|
| PSP | 256 | no (see design) |
| `_TEXT`, all code | 18,535 | |
| &nbsp;&nbsp;`fossil.obj` code (dispatcher, install/remove) | 1,208 | mostly |
| &nbsp;&nbsp;`uart.obj` code (ISR, rings, open/close) | 1,215 | mostly |
| &nbsp;&nbsp;`entry.obj` (signature stub) | 14 | yes |
| &nbsp;&nbsp;`main.obj` + `stubs.obj` | 1,326 | no |
| &nbsp;&nbsp;Open Watcom C library | ~14,800 | no |
| `uart.obj` BSS: 2 KB RX ring + 2 KB TX ring + state | 4,118 | yes |
| `fossil.obj` data + BSS (ident string, statics) | 88 | yes |
| `g_opts`, `g_transport`, `uart_transport` table | ~60 | yes |
| Rest of DGROUP: runtime data, stdio buffers, `main.obj` strings | ~4,100 | no |
| Stack (`STACK` segment) | 2,048 | no: handlers run on the caller's stack |
| Near heap growth (stdio, spawn) | ~8,000 | no |

What actually has to stay resident is about **2.4 KB of code and 4.3 KB of
data**, and some of that code (`uart_open`, `fossil_install`) only runs
at load time.

## Why not just reorder segments and truncate

The classic TSR trick is to link the resident code and data first and keep
the block only up to the end of them. In Open Watcom's small model that
fights the memory layout: code (`_TEXT`) and data (`DGROUP`) are separate
segments, laid out as `PSP | all code | all data`, so resident data always
sits after the transient code. Making them contiguous means custom segment
classes, `order` directives, and handlers that reach their data through
`CS`. That's possible but fragile, and it still keeps the 256-byte PSP.

## Design: a separate resident image

Split WWIVFOSS into two pieces:

1. **`WWIVFOSS.EXE`, the loader.** An ordinary C program that can use the
   whole runtime: option parsing, messages, spawning doors.
2. **The resident image.** A small, self-contained binary holding only the
   INT 14h dispatcher, the UART ISR and the ring operations. It's built in
   the tiny model and linked as a raw binary at offset 0, so it has no
   segment relocations. `wlink` rejects segment fixups in that format,
   which mechanically enforces the existing rule that interrupt-time code
   never calls the C library.

The loader embeds the image as a byte array (generated at build time by a
small `bin2c` step in Python) so we still ship a single file.

### Loading (`-L`)

1. Allocate one DOS memory block, sized for the image plus the requested
   buffers (INT 21h AH=48h). With upper memory available, link UMBs and
   switch the allocation strategy first (INT 21h AX=5803h / 5801h) so the
   block lands in upper memory and conventional memory cost is zero.
2. Copy the image into the block and fill in its header (below): port,
   flags, buffer offsets and sizes.
3. Do the load-time work from the loader, not the image: program the UART,
   save the old INT 14h and IRQ vectors into the header, point the vectors
   at the image's entry stubs, unmask the IRQ.
4. Mark the block as owned by itself (MCB owner = block segment) and
   name it `WWIVFOSS` (MCB bytes 8-15, DOS 4+) so `MEM /C` lists it and DOS
   doesn't free it when the loader exits.
5. Exit normally. No `_dos_keep()`, so the C runtime cleans up after
   itself and can't leave vectors of its own pointing into resident
   memory.

### Unloading (`-U`)

The private API stays (`AH=7Eh`, `BX='WF'`), but the query now returns the
image's segment. The loader checks the vectors as today, reads the saved
vectors and UART state from the image header, restores them itself, and
frees the block (INT 21h AH=49h). The image no longer needs `close` code
at all.

### Runner mode

The runner uses the same path: load the image, spawn the door, unload. One
code path for both modes, so runner mode gets the same tests for free. The
runner process itself still sits under the door while it runs; that's
separate and smaller (see "Later").

### Image header

At offset 0 of the image, so loader and image agree without relocations:

```c
struct wwivfoss_image {
  unsigned char  jmp[3];          /* not executed; keeps offset 0 non-zero */
  char           sig[8];          /* "WWIVFOSS" */
  unsigned short version;
  unsigned short int14_entry;     /* offsets of the entry stubs */
  unsigned short irq_entry;
  unsigned short old_int14_off, old_int14_seg;   /* filled by loader */
  unsigned short old_irq_off, old_irq_seg;
  unsigned short base;            /* UART I/O base */
  unsigned char  irq_vector;
  unsigned char  flags;           /* inband, force carrier, idle */
  unsigned short port;            /* FOSSIL port number we answer to */
  unsigned short rx_off, rx_mask; /* ring buffers follow the image */
  unsigned short tx_off, tx_mask;
  /* ... runtime state (heads, tails, remote line state) ... */
};
```

The FOSSIL signature still has to sit at offset 6 of the INT 14h handler,
so `int14_entry` points at the existing `entry.asm` stub, not at offset 0
of the image.

### Entry stubs

Both entry stubs (INT 14h and the UART IRQ) become small assembly routines
that save registers, set `DS` to `CS` (tiny model: data lives in the image
segment), call the C routine with a pointer to the saved registers, restore
and `IRET`. That replaces Open Watcom's `__interrupt` prologue, which loads
`DS` through a `DGROUP` segment fixup that a raw image can't have. Chaining
to the old INT 14h owner for ports that aren't ours becomes a `JMP FAR`
through the saved vector in the header, replacing `_chain_intr`.

### Configurable buffers

Add BNU/X00-style buffer options, for example `-R4` and `-T4` for 4 KB
receive and transmit rings (powers of two from 256 bytes to 16 KB). The
masks move from `#define`s into the header. Defaults stay at 2 KB each.

## Expected result

| | Today | After |
|---|---:|---:|
| Resident code + fixed data | ~33 KB | ~2.5 KB |
| Buffers (default) | 4 KB | 4 KB |
| PSP | 256 B | 0 |
| **Total, conventional memory** | **37 KB** | **~6.5 KB** |
| Total with UMBs available | 37 KB | 0 conventional |

## Tests

The existing matrix (QEMU and DOSBox-X, runner and resident, echo, hangup
and dtr) must keep passing unchanged. Add:

* **Free memory before `-L` and after `-U` must be identical** (no leaked
  blocks). Give FOSTEST a `/M` switch that prints the largest free block
  (INT 21h AH=48h with BX=FFFFh) and compare the two values in `test.sh`.
* **Resident size limit:** free memory before minus during `-L` must stay
  at or under the target (image + buffers + MCB). Fail the test if it
  grows, so regressions show up in CI.
* **Buffer options:** one run with `-R4 -T4`, checking 1Bh reports
  4096/4096.
* **Load high (later):** a QEMU boot configuration with an upper memory
  manager (JEMMEX from FreeDOS) to check that the block lands in a UMB and
  conventional free memory doesn't change.

## Risks

* **Open Watcom tiny model plus raw binary output** needs a spike first:
  confirm `wlink format raw bin` with offset 0 works for the image, that
  the compiler generates no segment fixups for our code, and how the image
  calls back into helpers (everything near, same segment).
* **Stack use:** handlers keep running on the caller's stack. Keep the C
  code shallow and check the deepest call path (block write into the TX
  ring with in-band escaping is the longest today).
* **`MCB` ownership tricks** behave slightly differently across DOS
  versions. Test on FreeDOS (QEMU) and DOSBox-X at minimum; MS-DOS 6.22 in
  QEMU would be a good third.

## Later

* **Runner footprint under the door:** the runner process (loader plus
  runtime) stays in memory while the door runs. If that matters, the runner
  can shrink its own block before spawning, or chain-execute the door via a
  tiny stub.
* **OS/2 pipe and NTVDM transports** become additional resident images (or
  image variants) behind the same header, chosen by the loader.
