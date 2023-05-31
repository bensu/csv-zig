const std = @import("std");
const fs = std.fs;
const csv_mod = @import("csv.zig");
const Type = std.builtin.Type;

// Want to do something that feels like a JIT

// 1. Read a schema from a file
// 2. Load a CSV file containing data that matches the schema
// 3. Print that

// I can start by doing that for a known schema and then seeing how to read the schema

const FieldDelimiter = ',';

const DynStruct = struct {
    id: []const u8,
    age: []const u8,

    pub fn init() DynStruct {
        return DynStruct{
            .id = undefined,
            .age = undefined,
        };
    }
};

// const csv_config = csv_mod.CsvConfig{
//     .col_sep = ',',
//     .row_sep = '\n',
//     .quote = '"',
// };

fn isAtomicTypeReadable(comptime T: type) bool {
    comptime switch (T) {
        []const u8 => return true,
        else => return false,
    };
}

fn isArrayType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info.tag == .ArrayType) {
        return true;
    } else {
        return false;
    }
}

const max_fields = 20;

fn initFields(comptime s: Type.Struct) []type {
    var field_types: [max_fields]type = undefined;
    var number_of_fields = 0;
    inline for (s.fields) |field, i| {
        field_types[i] = field.field_type;
        number_of_fields = number_of_fields + 1;
    }
    return field_types[0..number_of_fields];
}

fn readDynStruct(comptime T: type, allocator: std.mem.Allocator, reader: fs.File.Reader) !std.ArrayList(T) {
    // TODO: how to pick the right size for the buffer?
    var buffer = try allocator.alloc(u8, 4096);
    var csv = try csv_mod.CsvTokenizer(fs.File.Reader).init(reader, buffer, .{});

    // TODO: how long should the array be?
    var outArray = std.ArrayList(T).init(allocator);

    // compile time loop
    switch (@typeInfo(T)) {
        .Struct => |S| {
            const number_of_fields = S.fields.len;
            var continue_loop = true;
            while (continue_loop) {
                var draft_t: T = T.init();

                var fields_added: u32 = 0;
                inline for (S.fields) |F| {
                    const maybe_val = try csv.next();
                    std.debug.print("Getting next token {?}\n", .{maybe_val});
                    if (maybe_val) |val| {
                        switch (val) {
                            .field => {
                                std.debug.print("Adding field\n", .{});
                                @field(draft_t, F.name) = val.field;
                                fields_added = fields_added + 1;
                            },
                            .row_end => {
                                std.debug.print("Expected {} fields, got {}\n", .{ number_of_fields, fields_added });
                                // ERROR
                            },
                        }
                    } else {
                        // if we didn't get anything else here we are missing some
                        // fields in the last row, and we are discarding that
                        continue_loop = false;
                        break;
                    }
                }

                // were all the fields added?
                if (fields_added != number_of_fields) {
                    // ERROR
                }

                // We parsed a token per field, so we expect to be at the end of the row
                const maybe_val = try csv.next();
                if (maybe_val) |val| {
                    switch (val) {
                        .field => {
                            // ERROR
                        },
                        .row_end => {
                            std.debug.print("Adding to array\n", .{});
                            fields_added = 0;
                            try outArray.append(draft_t);
                        },
                    }
                } else {
                    // if we didn't get anything else here we are done
                    // TODO: maybe break here is enough?
                    continue_loop = false;
                    break;
                }
                std.debug.print("{}\n", .{draft_t});
            }
        },
        else => @compileError("T needs to be a struct"),
    }

    return outArray;
}

// Writing a CSV library that knew how to read directly into Structs would be cool

// something like

// readCSV(StructType, allocator, path) -> std.ArrayList(StructType)

// bonus points if it can be called during comptime to get a compile time array

// what is the ideal API?

// 1. Streaming so that the user can control how much memory to consume
// 2. Coerces to the types you already want
// 3. Efficient so that you can do it quickly if you want
// 4. Can read files partially

// var csv_reader = csv.Reader.init(T, allocator, file_reader, csv_config);
// csv_reader.nextRow() -> ?T
// if ?T is null, we are done

pub fn CsvParser(
    comptime T: type,
) type {
    return struct {
        const Self = @This();

        const Fields = switch (@typeInfo(T)) {
            .Struct => |S| S.fields,
            else => @compileError("T needs to be a struct"),
        };

        const number_of_fields: usize = Fields.len;

        allocator: std.mem.Allocator,
        reader: fs.File.Reader, // TODO: allow other types of readers
        csv_tokenizer: csv_mod.CsvTokenizer(fs.File.Reader),

        fn init(allocator: std.mem.Allocator, reader: fs.File.Reader) !Self {
            // TODO: How should this buffer work?
            var buffer = try allocator.alloc(u8, 4096);
            var csv_tokenizer = try csv_mod.CsvTokenizer(fs.File.Reader).init(reader, buffer, .{});
            return Self{
                .allocator = allocator,
                .reader = reader,
                .csv_tokenizer = csv_tokenizer,
            };
        }

        // Try to read a row and return a parsed T out of it if possible
        pub fn next(self: *Self) !?T {
            var draft_t: T = T.init();
            var fields_added: u32 = 0;
            inline for (Fields) |F| {
                const maybe_val = try self.csv_tokenizer.next();
                // std.debug.print("Getting next token {?}\n", .{maybe_val});
                if (maybe_val) |val| {
                    switch (val) {
                        .field => {
                            // std.debug.print("Adding field\n", .{});
                            @field(draft_t, F.name) = val.field;
                            fields_added = fields_added + 1;
                        },
                        .row_end => {
                            // std.debug.print("Expected {} fields, got {}\n", .{ number_of_fields, fields_added });
                            // ERROR
                            // we are missing some fields
                            break;
                        },
                    }
                } else {
                    // if we didn't get anything else here we are missing some
                    // fields in the last row, and we are discarding that
                    break;
                }
            }

            // consume the row_end
            const maybe_val = try self.csv_tokenizer.next();
            if (maybe_val) |val| {
                switch (val) {
                    .field => {
                        // TODO: ERROR
                        // we have more fields than we expected
                    },
                    .row_end => {
                        // Great
                    },
                }
            }

            // were all the fields added?
            if (fields_added == number_of_fields) {
                return draft_t;
            } else {
                // ERROR
                return null;
            }
        }
    };
}

pub fn main() anyerror!void {
    const file_path: []const u8 = "data.csv";
    const allocator = std.heap.page_allocator;

    // var file = try fs.cwd().openFile(file_path, .{});
    // defer file.close();
    // const reader = file.reader();
    // var myStruct = try readDynStruct(DynStruct, allocator, reader);
    // for (myStruct.items) |item| {
    //     std.debug.print("{}", .{item});
    // }

    // New
    var second_file = try fs.cwd().openFile(file_path, .{});
    defer second_file.close();
    const second_reader = second_file.reader();

    var csv_parser = try CsvParser(DynStruct).init(allocator, second_reader);
    const first_row = try csv_parser.next();
    std.debug.print("Parsed {?}\n", .{first_row});
    const second_row = try csv_parser.next();
    std.debug.print("Parsed {?}\n", .{second_row});
    const no_row = try csv_parser.next();
    std.debug.print("No field {?}", .{no_row});

    var third_file = try fs.cwd().openFile(file_path, .{});
    defer third_file.close();
    const third_reader = third_file.reader();

    var csv_parser_two = try CsvParser(DynStruct).init(allocator, third_reader);
    while (try csv_parser_two.next()) |row| {
        std.debug.print("Parsed {}\n", .{row});
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
