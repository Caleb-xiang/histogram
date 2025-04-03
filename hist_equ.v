module hist_equ
#(
    parameter  [9:0] IMG_HDISP = 10'd100,  //640*480
    parameter  [9:0] IMG_VDISP = 10'd100
)
(
    input   wire            clk             ,
    input   wire            rst_n           ,

    input   wire            per_frame_vsync ,        //每帧的垂直同步信号
    input   wire            per_frame_href  ,         //每帧的水平同步信号
    input   wire            per_frame_de    ,        //数据有效信号
    input   wire    [7:0]   per_img_Y       ,

    output  wire            post_frame_vsync,
    output  wire            post_frame_href ,
    output  wire            post_frame_clken,
    output  wire    [7:0]   post_img_Y
);

//************** Parameter and Internal Signal **************//

localparam IMG_TOTAL_PIXEL = 10000;  //一帧图像的总像素数，RAM读写数据只有16位，没有14位
localparam IMG_MAX_GRAY   = 256;     //图像中可能的灰度等级数量

wire    [15:0]      ramA_stas_rd_data;
reg                 ramA_stats_wren;
reg                 vsync_delay;

reg     [7:0]       ramB_stas_addr;
reg                 ramB_stas_rden;
wire    [15:0]      ramB_stas_rd_data;

reg                 ramB_stas_wren;

reg                 ram_accu_wr;
reg     [7:0]       ram_accu_wr_addr;
wire    [18:0]      ram_accu_wr_data;

wire    [18:0]      ram_accu_rddata;


//************************ Main Code ************************//


//************************ 直方图统计 ************************//

//摄像头输入的灰度数据有效时，会先进行读RAM操作，然后将读出的数据加1后，再次写入相同地址
//读操作需要一个时钟周期，因此“写使能”直接将输入的Valid信号延迟一个时钟周期即可
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        ramA_stats_wren <= 1'b0;
    else
        ramA_stats_wren <= per_frame_de;
end

//双端口RAM，用于统计一帧图像的灰度直方图
ram_2port_stats     ram_2port_stats_inst
(
    //端口A：摄像头输出的灰度数据作为RAM地址，先将该地址中的数据读出来，加1后再写入RAM1中
    .clock_a    (clk),
    .aclr_a     (!rst_n),
    .rden_a     (per_frame_de),         //读端口A
    .address_a  (per_img_Y),
    .q_a        (ramA_stas_rd_data),
    .wren_a     (ramA_stats_wren),      //写端口A
    .data_a     (ramA_stas_rd_data+1),  //直方图统计过程中，写入RAM的数据为（当前地址的数据+1）

    //端口B：一帧结束后读出RAM中的数据进行寄存，下一帧开始前将RAM初始化为0
    .clock_b    (clk),
    .aclr_b     (1'b0),
    .rden_b     (ramB_stas_rden),         //读端口B
    .address_b  (ramB_stas_addr),
    .q_b        (ramB_stas_rd_data),
    .wren_b     (ramB_stas_wren),         //写端口B
    .data_b     (16'd0)                 //初始化过程中，写入RAM的数据为0
);

//采集摄像头场同步信号上升/下降沿
wire vsync_negedge;
wire vsync_posedge;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        vsync_delay <= 1'b0;
    else
        vsync_delay <= per_frame_vsync;
end

assign vsync_negedge = vsync_delay & (!per_frame_vsync);
assign vsync_posedge = (!vsync_delay) & per_frame_vsync;

//场同步“上升沿”表示前一帧直方图统计结束，此时将RAM中的数据读出，寄存到VGA显存RAM中
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ramB_stas_rden <= 1'b0;
    else begin
        if (vsync_posedge) //上升沿拉高端口b的读使能，并维持256个时钟周期
            ramB_stas_rden <= 1'b1;
        else if (ramB_stas_addr == 8'd255)
            ramB_stas_rden <= 1'b0;
    end
end

//场同步“下降沿”表示新的一帧开始，此时将RAM初始化为0
//RAM的异步复位端口只能将输出端置0，初始化需要通过写操作进行
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ramB_stas_wren <= 1'b0;
    else begin
        if (vsync_negedge) //下降沿拉高端口b的写使能，并维持256个时钟周期
            ramB_stas_wren <= 1'b1;
        else if (ramB_stas_addr == 8'd255)
            ramB_stas_wren <= 1'b0;
    end
end

//对RAM的端口B进行读写操作时，都要遍历整个RAM的地址空间
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ramB_stas_addr <= 8'd0;
    else if (ramB_stas_addr == 8'd255)
            ramB_stas_addr <= 8'd0;
    else if (ramB_stas_rden)            //遍历读操作地址
            ramB_stas_addr <= ramB_stas_addr + 1'b1;
    else if (ramB_stas_wren)            //遍历写操作地址
            ramB_stas_addr <= ramB_stas_addr + 1'b1;
    else
            ramB_stas_addr <= 8'd0;
end

//////////////////////////////////////////
//    计算累积直方图
/////////////////////////////////////////

//从前一个RAM中读出直方图统计信息，延迟一个时钟周期拉高VGA显存RAM的写使能
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ram_accu_wr <= 1'b0;
    else
        ram_accu_wr <= ramB_stas_rden;//读完再写
end

reg [18:0] his_sum; //累积直方图结果

//前一个RAM端口B读数据有效时，对输出的直方图进行累加
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        his_sum <= 19'd0;
    else begin
        if (vsync_negedge)
            his_sum <= 19'd0;
        else if (ram_accu_wr)
            his_sum <= his_sum + ramB_stas_rd_data;
    end
end

assign ram_accu_wr_data = his_sum + ramB_stas_rd_data;//不能直接取ramB_stas_rd_data


//将直方图统计信息寄存到VGA显存RAM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ram_accu_wr_addr <= 8'd0;
    else
        ram_accu_wr_addr <= ramB_stas_addr;
end

//累积直方图RAM，用于在每一帧图像的直方图信息统计完毕后，累积统计结果，该结果会用于直方图均衡
ram_2port_accu      ram_2port_accu_inst
(
    .clock      (clk),
    .aclr       (!rst_n),
    .wren       (ram_accu_wr),
    .wraddress  (ram_accu_wr_addr),
    .data       (ram_accu_wr_data), //写入的数据是从前一个RAM端口B读出的数据 + 累积结果
    .rden       (per_frame_de), //摄像头输入图像时，使用上一帧的直方图统计信息
    .rdaddress  (per_img_Y),
    .q          (ram_accu_rddata)
);


//////////////////////////////////////////
//    直方图均衡
//////////////////////////////////////////

reg [26:0] data_mult;  //乘法运算结果

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_mult <= 27'd0;
    else
        data_mult <= ram_accu_rddata * (IMG_MAX_GRAY - 1);
end

reg [7:0] data_div; //除法运算结果

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_div <= 8'd0;
    else
        data_div <= data_mult / IMG_TOTAL_PIXEL;
end

//-----------------------------------
//延迟三个时钟周期以达到与数据同步
reg [2:0] per_frame_vsync_r;
reg [2:0] per_frame_href_r;
reg [2:0] per_frame_de_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        per_frame_vsync_r <= 0;
        per_frame_href_r <= 0;
        per_frame_de_r <= 0;
    end else begin
        per_frame_vsync_r <= {per_frame_vsync_r[1:0], per_frame_vsync};
        per_frame_href_r <= {per_frame_href_r[1:0], per_frame_href};
        per_frame_de_r <= {per_frame_de_r[1:0], per_frame_de};
    end
end

assign post_frame_vsync = per_frame_vsync_r[2];
assign post_frame_href = per_frame_href_r[2];
assign post_frame_clken = per_frame_de_r[2];
assign post_img_Y = post_frame_href ? data_div : 8'd0;



endmodule

