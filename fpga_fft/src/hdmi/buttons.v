// buttons.v — two push buttons in, one clean "pressed" pulse per press out.
//
// A mechanical button bounces: its contact opens and closes many times within a few
// milliseconds of a press. The input is looked at only every 2^18 clocks (3.5 ms at
// 74.25 MHz), and a press counts when it reads "down" twice in a row after reading "up".
// The Tang Nano 20K's buttons read 1 while pressed (pull-down on the pin).
module buttons (
    input  wire       clk,
    input  wire [1:0] btn,            // raw pins
    output reg  [1:0] pressed = 2'b00 // one-clock pulse per press
);
    reg [1:0] m = 0, s = 0;           // synchroniser
    reg [17:0] tick = 0;
    reg [1:0] r0 = 0, r1 = 0;         // last two slow samples
    always @(posedge clk) begin
        m <= btn;  s <= m;
        tick <= tick + 1'b1;
        pressed <= 2'b00;
        if (tick == 0) begin
            r0 <= s;  r1 <= r0;
            pressed <= s & r0 & ~r1;  // down, down, after up
        end
    end
endmodule
