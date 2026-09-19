/*
 * Copyright (c) 2024 Ciro Cattuto (original VGA / board-simulation scaffolding)
 * Etch-a-Sketch adaptation, 2026
 * based on the VGA examples by Uri Shaked
 * Gamepad Pmod interface by Pat Deegan (gamepad_pmod.v)
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_etch_a_sketch (
  input  wire [7:0] ui_in,    // Dedicated inputs
  output wire [7:0] uo_out,   // Dedicated outputs
  input  wire [7:0] uio_in,   // IOs: Input path
  output wire [7:0] uio_out,  // IOs: Output path
  output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
  input  wire       ena,      // always 1 when the design is powered, so you can ignore it
  input  wire       clk,      // clock
  input  wire       rst_n     // reset_n - low to reset
);

  // ------------------------------------------------------------------
  // INPUT: Gamepad Pmod (serial), NOT individual button pins.
  //   ui_in[4] = pmod_latch
  //   ui_in[5] = pmod_clk
  //   ui_in[6] = pmod_data
  // The Pmod streams all 12 button states serially; gamepad_pmod_single
  // shifts them in and hands back one wire per button.
  //
  // Button map used by this design:
  //   D-pad UP / DOWN / LEFT / RIGHT -> ONE press = ONE step of the pen
  //                                     (holding a direction does not repeat;
  //                                      UP+RIGHT etc. pressed together = diagonal step)
  //   START or A                     -> lower / lift the pen
  //   X                              -> erase the sketch (pen stays where it is, lifted)
  //
  // The pen starts LIFTED (hollow black square) in the middle of the screen.
  // Walk it anywhere you like without drawing, then press START/A to put
  // the pen down - that cell is inked and every step after it draws.
  // ------------------------------------------------------------------

  // ----------------------- VGA generation ----------------------------
  wire hsync, vsync;
  wire [1:0] R, G, B;
  wire video_active;
  wire [9:0] pix_x, pix_y;

  // TinyVGA PMOD
  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  assign uio_out = 0;
  assign uio_oe  = 0;

  wire boot_reset = ~rst_n;

  hvsync_generator hvsync_gen (
    .clk(clk),
    .reset(boot_reset),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(video_active),
    .hpos(pix_x),
    .vpos(pix_y)
  );

  // ----------------------- gamepad -----------------------------------
  wire inp_b, inp_y, inp_select, inp_start, inp_up, inp_down;
  wire inp_left, inp_right, inp_a, inp_x, inp_l, inp_r, inp_present;

  gamepad_pmod_single gamepad (
    .rst_n     (rst_n),
    .clk       (clk),
    .pmod_data (ui_in[6]),
    .pmod_clk  (ui_in[5]),
    .pmod_latch(ui_in[4]),
    .b(inp_b), .y(inp_y), .select(inp_select), .start(inp_start),
    .up(inp_up), .down(inp_down), .left(inp_left), .right(inp_right),
    .a(inp_a), .x(inp_x), .l(inp_l), .r(inp_r),
    .is_present(inp_present)
  );

  // ----------------------- canvas geometry ----------------------------
  // 64 x 32 grid of 8x8-pixel "ink cells" -> 512 x 256 pixel canvas.
  // The canvas is the grey Etch A Sketch screen, sitting under the title
  // and above the two dials on the 640x480 red frame.
  localparam logWIDTH   = 6, logHEIGHT = 5;
  localparam WIDTH      = 2 ** logWIDTH;   // 64
  localparam HEIGHT     = 2 ** logHEIGHT;  // 32
  localparam BOARD_SIZE = WIDTH * HEIGHT;  // 2048 cells

  localparam [9:0] CANVAS_X0 = 10'd64;     // canvas: x 64..575, y 88..343
  localparam [9:0] CANVAS_X1 = 10'd576;
  localparam [9:0] CANVAS_Y0 = 10'd88;
  localparam [9:0] CANVAS_Y1 = 10'd344;

  wire canvas_active = (pix_x >= CANVAS_X0) && (pix_x < CANVAS_X1) &&
                       (pix_y >= CANVAS_Y0) && (pix_y < CANVAS_Y1);

  // dark-red inset lip around the grey screen (4 px)
  wire screen_lip = (pix_x >= CANVAS_X0 - 10'd4) && (pix_x < CANVAS_X1 + 10'd4) &&
                    (pix_y >= CANVAS_Y0 - 10'd4) && (pix_y < CANVAS_Y1 + 10'd4);

  reg board_state [0:BOARD_SIZE-1];  // 1 = inked cell

  /* verilator lint_off UNUSEDSIGNAL */
  wire [9:0]  rel_x = pix_x - CANVAS_X0;
  wire [9:0]  rel_y = pix_y - CANVAS_Y0;
  /* verilator lint_on UNUSEDSIGNAL */
  
  wire [10:0] cell_index = {rel_y[7:3], rel_x[8:3]};

  // ----------------------- pen (cursor) state --------------------------
  localparam [5:0] WIDTH_MAX = 63;
  localparam [4:0] HEIGHT_MAX = 31;
  localparam integer CENTER_X   = WIDTH  / 2;
  localparam integer CENTER_Y   = HEIGHT / 2;

  reg [logWIDTH-1:0]  pen_x; 
  reg [logHEIGHT-1:0] pen_y;
  reg                 pen_up;   // 1 = pen lifted (moves without drawing), 0 = pen down (drawing)

  wire [10:0] pen_index = {pen_y, pen_x};

  // ----------------------- button edge detection -----------------------
  // The gamepad decoder outputs are already synchronised to clk, so one
  // delay stage per button is enough to detect a fresh press. Every
  // button below acts only on the press itself (one-cycle pulse), which
  // is what makes "one key press = one step".
  wire pause_btn = inp_start | inp_a;

  reg up_d, down_d, left_d, right_d, erase_d, pause_d;
  always @(posedge clk) begin
    if (boot_reset) begin
      up_d    <= 1'b0;
      down_d  <= 1'b0;
      left_d  <= 1'b0;
      right_d <= 1'b0;
      erase_d <= 1'b0;
      pause_d <= 1'b0;
    end else begin
      up_d    <= inp_up;
      down_d  <= inp_down;
      left_d  <= inp_left;
      right_d <= inp_right;
      erase_d <= inp_x;
      pause_d <= pause_btn;
    end
  end

  wire up_pulse    = inp_up    & ~up_d;
  wire down_pulse  = inp_down  & ~down_d;
  wire left_pulse  = inp_left  & ~left_d;
  wire right_pulse = inp_right & ~right_d;
  wire erase_pulse = inp_x     & ~erase_d;     // one-cycle pulse on X press
  wire pause_pulse = pause_btn & ~pause_d;     // one-cycle pulse on START/A press

  // opposite presses landing on the same cycle cancel out;
  // UP/DOWN + LEFT/RIGHT on the same cycle = one diagonal step
  wire move_up    = up_pulse    & ~down_pulse;
  wire move_down  = down_pulse  & ~up_pulse;
  wire move_left  = left_pulse  & ~right_pulse;
  wire move_right = right_pulse & ~left_pulse;

  // ----------------------- action state machine -------------------------
  // ACTION_IDLE  : normal operation (pen moves / draws)
  // ACTION_CLEAR : sweeps every cell to 0; runs at boot and when X is pressed
  localparam ACTION_IDLE = 1'b0, ACTION_CLEAR = 1'b1;
  reg action;
  reg [logWIDTH+logHEIGHT-1:0] clear_index;
  wire clear_last = (clear_index == BOARD_SIZE - 1);
  wire idle       = (action == ACTION_IDLE);

  always @(posedge clk) begin
    if (boot_reset) begin
      action      <= ACTION_CLEAR;
      clear_index <= 0;
    end else begin
      case (action)
        ACTION_IDLE: begin
          if (erase_pulse) begin
            action      <= ACTION_CLEAR;
            clear_index <= 0;
          end
        end
        ACTION_CLEAR: begin
          if (clear_last) begin
            clear_index <= 0;
            action      <= ACTION_IDLE;
          end else begin
            clear_index <= clear_index + 1;
          end
        end
        default: action <= ACTION_IDLE;
      endcase
    end
  end

  // ----------------------- pen motion -----------------------------------
  // Each press moves the pen exactly one cell (clamped at the canvas edge).
  wire [logWIDTH-1:0]  next_pen_x = move_right ? (pen_x == WIDTH_MAX  ? pen_x : pen_x + 1'b1) :
                                     move_left  ? (pen_x == 0         ? pen_x : pen_x - 1'b1) :
                                     pen_x;
  wire [logHEIGHT-1:0] next_pen_y = move_down  ? (pen_y == HEIGHT_MAX ? pen_y : pen_y + 1'b1) :
                                     move_up    ? (pen_y == 0         ? pen_y : pen_y - 1'b1) :
                                     pen_y;
  wire [10:0] next_pen_index = {next_pen_y, next_pen_x};
  wire pen_moved = (next_pen_x != pen_x) || (next_pen_y != pen_y);

  // pen lower / lift request (START or A)
  wire lower_pen = idle & pause_pulse &  pen_up;
  wire raise_pen = idle & pause_pulse & ~pen_up;
  wire pen_down_next = pen_up ? lower_pen : ~raise_pen;

  // ink the destination cell when the pen ends the cycle down and either
  // moved this cycle or was just lowered (so the start point is marked)
  wire ink_now = idle & pen_down_next & (pen_moved | lower_pen);

  always @(posedge clk) begin
    if (boot_reset) begin
     pen_x <= CENTER_X[5:0];    
     pen_y <= CENTER_Y[4:0];   // walk it anywhere before you start drawing
    end else if (idle) begin
      pen_x <= next_pen_x;
      pen_y <= next_pen_y;
    end
  end

  always @(posedge clk) begin
    if (boot_reset)
      pen_up <= 1'b1;                 // start (and restart) with the pen lifted
    else if (action == ACTION_CLEAR && clear_last)
      pen_up <= 1'b1;                 // after an erase: pen stays put, lifted
    else if (pause_pulse && idle)
      pen_up <= ~pen_up;
  end

  // ----------------------- ink buffer write port -------------------------
  always @(posedge clk) begin
    if (action == ACTION_CLEAR)
      board_state[clear_index] <= 1'b0;
    else if (ink_now)
      board_state[next_pen_index] <= 1'b1;
  end

  // ----------------------- Etch A Sketch artwork ---------------------------
  // Red frame with a bevel; mitered corner seams.
  localparam [9:0] BEVEL = 10'd12;
  wire [9:0] d_l = pix_x;
  wire [9:0] d_r = 10'd639 - pix_x;
  wire [9:0] d_t = pix_y;
  wire [9:0] d_b = 10'd479 - pix_y;
  wire [9:0] d_h = (d_l < d_r) ? d_l : d_r;    // distance to nearest left/right edge
  wire [9:0] d_v = (d_t < d_b) ? d_t : d_b;    // distance to nearest top/bottom edge
  wire in_bevel   = (d_h < BEVEL) || (d_v < BEVEL);
  wire bevel_seam = (d_h == d_v);              // 45-degree mitre line in the corners

  // Title: MAGIC  ETCH A SKETCH  SCREEN (cream, with a dark-red drop shadow)
  wire title_on;
  wire title_shadow_on;
  etch_title title_fg (.px(pix_x),          .py(pix_y),          .lit(title_on));
  etch_title title_sh (.px(pix_x - 10'd3),  .py(pix_y - 10'd3),  .lit(title_shadow_on));

  // The two white dials with a blue (horizontal) and a red (vertical) star
  wire       knob_on;
  wire [5:0] knob_rgb;
  etch_knobs knobs (.px(pix_x), .py(pix_y), .lit(knob_on), .rgb(knob_rgb));

  // ----------------------- pixel colors -----------------------------------
  // 2 bits per channel -> {R,G,B} = 6 bits. Real-life colours, nearest 2-bit match:
  localparam [5:0] COL_BLACK  = 6'b00_00_00;
  localparam [5:0] COL_BODY   = 6'b11_00_00;  // Etch A Sketch red   (255,   0,   0)
  localparam [5:0] COL_BEVEL  = 6'b11_01_01;  // lighter bevel red   (255,  85,  85)
  localparam [5:0] COL_LIP    = 6'b10_00_00;  // dark red inset lip  (170,   0,   0)
  localparam [5:0] COL_CREAM  = 6'b11_11_10;  // title cream         (255, 255, 170)
  localparam [5:0] COL_SCREEN = 6'b10_10_10;  // silver-grey screen  (170, 170, 170)
  localparam [5:0] COL_INK    = 6'b00_00_00;  // black line          (  0,   0,   0)
  localparam [5:0] COL_PEN    = 6'b00_00_00;  // black pen block

  wire cell_drawn  = board_state[cell_index];
  wire is_pen_cell = (cell_index == pen_index);
  // pen down: solid black block.  pen lifted: hollow black square (always visible,
  // drawn in grey where it sits on ink so it can still be seen).
  wire cell_edge   = (rel_x[2:0] == 3'd0) || (rel_x[2:0] == 3'd7) ||
                     (rel_y[2:0] == 3'd0) || (rel_y[2:0] == 3'd7);
  wire show_cursor = is_pen_cell & (~pen_up | cell_edge);

  reg [5:0] rgb;
  always @* begin
    if (!video_active)
      rgb = COL_BLACK;
    else if (in_bevel)
      rgb = bevel_seam ? COL_BODY : COL_BEVEL;
    else if (canvas_active)
      rgb = show_cursor ? ((pen_up & cell_drawn) ? COL_SCREEN : COL_PEN)
                        : (cell_drawn ? COL_INK : COL_SCREEN);
    else if (screen_lip)
      rgb = COL_LIP;
    else if (title_on)
      rgb = COL_CREAM;
    else if (title_shadow_on)
      rgb = COL_LIP;
    else if (knob_on)
      rgb = knob_rgb;
    else
      rgb = COL_BODY;
  end

  assign R = rgb[5:4];
  assign G = rgb[3:2];
  assign B = rgb[1:0];

  // Suppress unused-signal warnings
  wire _unused_ok = &{ena, uio_in, ui_in[7], ui_in[3:0],
                      inp_b, inp_y, inp_select, inp_l, inp_r, inp_present};

endmodule


// ======================================================================
// Title text: "MAGIC" (small)  "ETCH A SKETCH" (big)  "SCREEN" (small)
// 5x7 pixel font, 6-unit character cell (5 glyph columns + 1 gap).
//   big   text: 1 font unit = 4 px  -> 24 px per character, 28 px tall
//   small text: 1 font unit = 2 px  -> 12 px per character, 14 px tall
// `lit` is high when (px,py) is a lit pixel of any of the three words.
// ======================================================================
module etch_title (
  input  wire [9:0] px,
  input  wire [9:0] py,
  output wire       lit
);
  localparam [9:0] TITLE_X  = 10'd166;  // 13 chars * 24 = 312 px wide
  localparam [9:0] TITLE_Y  = 10'd30;   // 28 px tall
  localparam [9:0] MAGIC_X  = 10'd92;   //  5 chars * 12 =  60 px wide
  localparam [9:0] SCREEN_X = 10'd490;  //  6 chars * 12 =  72 px wide
  localparam [9:0] SMALL_Y  = 10'd44;   // 14 px tall, bottom-aligned with the big text

  localparam [3:0] C_SP = 4'd0,  C_A = 4'd1, C_C = 4'd2, C_E = 4'd3, C_G = 4'd4,
                   C_H  = 4'd5,  C_I = 4'd6, C_K = 4'd7, C_M = 4'd8, C_N = 4'd9,
                   C_R  = 4'd10, C_S = 4'd11, C_T = 4'd12;

  function [4:0] glyph_row;
    input [3:0] ch;
    input [2:0] row;
    begin
      case (ch)
        C_A: begin
          case (row)
            3'd0: glyph_row = 5'b01110;
            3'd1: glyph_row = 5'b10001;
            3'd2: glyph_row = 5'b10001;
            3'd3: glyph_row = 5'b11111;
            3'd4: glyph_row = 5'b10001;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_C: begin
          case (row)
            3'd0: glyph_row = 5'b01110;
            3'd1: glyph_row = 5'b10001;
            3'd2: glyph_row = 5'b10000;
            3'd3: glyph_row = 5'b10000;
            3'd4: glyph_row = 5'b10000;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b01110;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_E: begin
          case (row)
            3'd0: glyph_row = 5'b11111;
            3'd1: glyph_row = 5'b10000;
            3'd2: glyph_row = 5'b10000;
            3'd3: glyph_row = 5'b11110;
            3'd4: glyph_row = 5'b10000;
            3'd5: glyph_row = 5'b10000;
            3'd6: glyph_row = 5'b11111;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_G: begin
          case (row)
            3'd0: glyph_row = 5'b01110;
            3'd1: glyph_row = 5'b10001;
            3'd2: glyph_row = 5'b10000;
            3'd3: glyph_row = 5'b10111;
            3'd4: glyph_row = 5'b10001;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b01111;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_H: begin
          case (row)
            3'd0: glyph_row = 5'b10001;
            3'd1: glyph_row = 5'b10001;
            3'd2: glyph_row = 5'b10001;
            3'd3: glyph_row = 5'b11111;
            3'd4: glyph_row = 5'b10001;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_I: begin
          case (row)
            3'd0: glyph_row = 5'b01110;
            3'd1: glyph_row = 5'b00100;
            3'd2: glyph_row = 5'b00100;
            3'd3: glyph_row = 5'b00100;
            3'd4: glyph_row = 5'b00100;
            3'd5: glyph_row = 5'b00100;
            3'd6: glyph_row = 5'b01110;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_K: begin
          case (row)
            3'd0: glyph_row = 5'b10001;
            3'd1: glyph_row = 5'b10010;
            3'd2: glyph_row = 5'b10100;
            3'd3: glyph_row = 5'b11000;
            3'd4: glyph_row = 5'b10100;
            3'd5: glyph_row = 5'b10010;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_M: begin
          case (row)
            3'd0: glyph_row = 5'b10001;
            3'd1: glyph_row = 5'b11011;
            3'd2: glyph_row = 5'b10101;
            3'd3: glyph_row = 5'b10101;
            3'd4: glyph_row = 5'b10001;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_N: begin
          case (row)
            3'd0: glyph_row = 5'b10001;
            3'd1: glyph_row = 5'b11001;
            3'd2: glyph_row = 5'b10101;
            3'd3: glyph_row = 5'b10011;
            3'd4: glyph_row = 5'b10001;
            3'd5: glyph_row = 5'b10001;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_R: begin
          case (row)
            3'd0: glyph_row = 5'b11110;
            3'd1: glyph_row = 5'b10001;
            3'd2: glyph_row = 5'b10001;
            3'd3: glyph_row = 5'b11110;
            3'd4: glyph_row = 5'b10100;
            3'd5: glyph_row = 5'b10010;
            3'd6: glyph_row = 5'b10001;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_S: begin
          case (row)
            3'd0: glyph_row = 5'b01111;
            3'd1: glyph_row = 5'b10000;
            3'd2: glyph_row = 5'b10000;
            3'd3: glyph_row = 5'b01110;
            3'd4: glyph_row = 5'b00001;
            3'd5: glyph_row = 5'b00001;
            3'd6: glyph_row = 5'b11110;
            default: glyph_row = 5'b00000;
          endcase
        end
        C_T: begin
          case (row)
            3'd0: glyph_row = 5'b11111;
            3'd1: glyph_row = 5'b00100;
            3'd2: glyph_row = 5'b00100;
            3'd3: glyph_row = 5'b00100;
            3'd4: glyph_row = 5'b00100;
            3'd5: glyph_row = 5'b00100;
            3'd6: glyph_row = 5'b00100;
            default: glyph_row = 5'b00000;
          endcase
        end
        default: glyph_row = 5'b00000;
      endcase
    end
  endfunction

  wire in_title  = (px >= TITLE_X)  && (px < TITLE_X  + 10'd312) &&
                   (py >= TITLE_Y)  && (py < TITLE_Y  + 10'd28);
  wire in_magic  = (px >= MAGIC_X)  && (px < MAGIC_X  + 10'd60)  &&
                   (py >= SMALL_Y)  && (py < SMALL_Y  + 10'd14);
  wire in_screen = (px >= SCREEN_X) && (px < SCREEN_X + 10'd72)  &&
                   (py >= SMALL_Y)  && (py < SMALL_Y  + 10'd14);
  wire in_any    = in_title | in_magic | in_screen;

  // position inside the active word, in pixels
  /* verilator lint_off UNUSEDSIGNAL */
  wire [9:0] lx = in_title ? (px - TITLE_X) : in_magic ? (px - MAGIC_X) : (px - SCREEN_X);
  wire [9:0] ly = in_title ? (py - TITLE_Y) : (py - SMALL_Y);
  /* verilator lint_on UNUSEDSIGNAL */

  // ... and in font units (divide by 4 for the big word, by 2 for the small ones)
  wire [8:0] ux  = in_title ? {1'b0, lx[9:2]} : lx[9:1];
  wire [2:0] row = in_title ? ly[4:2] : ly[3:1];

  /* verilator lint_off WIDTHTRUNC */
  wire [3:0] idx = ux / 9'd6;   // which character
  wire [2:0] col = ux % 9'd6;   // which font column inside it (5 = gap)
  /* verilator lint_on WIDTHTRUNC */
  
  reg [3:0] ch;
  always @* begin
    ch = C_SP;
    if (in_title) begin
      case (idx)
        4'd0:  ch = C_E;
        4'd1:  ch = C_T;
        4'd2:  ch = C_C;
        4'd3:  ch = C_H;
        4'd4:  ch = C_SP;
        4'd5:  ch = C_A;
        4'd6:  ch = C_SP;
        4'd7:  ch = C_S;
        4'd8:  ch = C_K;
        4'd9:  ch = C_E;
        4'd10: ch = C_T;
        4'd11: ch = C_C;
        4'd12: ch = C_H;
        default: ch = C_SP;
      endcase
    end else if (in_magic) begin
      case (idx)
        4'd0: ch = C_M;
        4'd1: ch = C_A;
        4'd2: ch = C_G;
        4'd3: ch = C_I;
        4'd4: ch = C_C;
        default: ch = C_SP;
      endcase
    end else if (in_screen) begin
      case (idx)
        4'd0: ch = C_S;
        4'd1: ch = C_C;
        4'd2: ch = C_R;
        4'd3: ch = C_E;
        4'd4: ch = C_E;
        4'd5: ch = C_N;
        default: ch = C_SP;
      endcase
    end
  end

  wire [4:0] bits = glyph_row(ch, row);
  assign lit = in_any && (col < 3'd5) && bits[3'd4 - col];

endmodule


// ======================================================================
// The two Etch A Sketch dials, bottom-left and bottom-right.
// White ring, thin grey line, shaded inner disc (light from the right)
// and a 16x16 star scaled 3x (blue on the left dial, red on the right).
// ======================================================================
module etch_knobs (
  input  wire [9:0] px,
  input  wire [9:0] py,
  output reg        lit,
  output reg  [5:0] rgb
);
  localparam [9:0] CX_L = 10'd68;    // dial centres
  localparam [9:0] CX_R = 10'd571;
  localparam [9:0] CY   = 10'd418;

  localparam [5:0] COL_WHITE  = 6'b11_11_11;
  localparam [5:0] COL_GREY   = 6'b10_10_10;
  localparam [5:0] COL_STAR_L = 6'b01_01_10;  // blue (85, 85, 170)
  localparam [5:0] COL_STAR_R = 6'b11_00_00;  // red  (255, 0, 0)

  function [15:0] star_row;
    input [3:0] r;
    begin
      case (r)
        4'd0: star_row = 16'b0000000000000000;
        4'd1: star_row = 16'b0000000110000000;
        4'd2: star_row = 16'b0000000110000000;
        4'd3: star_row = 16'b0000000110000000;
        4'd4: star_row = 16'b0000001111000000;
        4'd5: star_row = 16'b0000001111000000;
        4'd6: star_row = 16'b1111111111111111;
        4'd7: star_row = 16'b0111111111111110;
        4'd8: star_row = 16'b0011111111111100;
        4'd9: star_row = 16'b0000111111110000;
        4'd10: star_row = 16'b0000111111110000;
        4'd11: star_row = 16'b0000111111110000;
        4'd12: star_row = 16'b0000111111110000;
        4'd13: star_row = 16'b0001111001111000;
        4'd14: star_row = 16'b0001100000011000;
        4'd15: star_row = 16'b0001000000001000;
        default: star_row = 16'b0;
      endcase
    end
  endfunction

  wire right_half = (px >= 10'd320);
  wire [9:0] cx   = right_half ? CX_R : CX_L;

  wire dx_neg = (px < cx);   // left of this dial's centre
  wire dy_neg = (py < CY);
  wire [9:0] adx = dx_neg ? (cx - px) : (px - cx);
  wire [9:0] ady = dy_neg ? (CY - py) : (py - CY);

  // squared distance from the centre (only meaningful inside the 92x92 box)
  wire        near = (adx < 10'd46) && (ady < 10'd46);
  wire [5:0]  sx   = adx[5:0];
  wire [5:0]  sy   = ady[5:0];
  wire [11:0] d2   = sx * sx + sy * sy;

  // star: 48x48 px box centred on the dial, 3 px per bitmap pixel
  wire [9:0] lxs = dx_neg ? (10'd24 - adx) : (10'd24 + adx);
  wire [9:0] lys = dy_neg ? (10'd24 - ady) : (10'd24 + ady);
  wire       in_star_box = (lxs < 10'd48) && (lys < 10'd48);
  /* verilator lint_off WIDTHTRUNC */
  wire [3:0] stx = lxs / 10'd3;
  wire [3:0] sty = lys / 10'd3;
  /* verilator lint_on WIDTHTRUNC */
  wire [15:0] star_bits = star_row(sty);
  wire        star_on   = in_star_box && star_bits[4'd15 - stx];

  always @* begin
    lit = 1'b0;
    rgb = COL_WHITE;
    if (near && d2 < 12'd2025) begin                 // radius 45: dial
      lit = 1'b1;
      if (star_on && d2 < 12'd1444)                  // star sits on the inner disc
        rgb = right_half ? COL_STAR_R : COL_STAR_L;
      else if (d2 >= 12'd1600)                       // radius 40..45: white ring
        rgb = COL_WHITE;
      else if (d2 >= 12'd1444)                       // radius 38..40: thin grey line
        rgb = COL_GREY;
      else if (dx_neg && adx > 10'd22)               // inner disc, left side: shaded
        rgb = COL_GREY;
      else if (dx_neg && adx > 10'd6)                // dithered transition
        rgb = (px[0] ^ py[0]) ? COL_WHITE : COL_GREY;
      else
        rgb = COL_WHITE;
    end
  end

endmodule
