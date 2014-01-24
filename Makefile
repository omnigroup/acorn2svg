
CC     = xcrun clang
COPTS ?= -g -Os -Wall -flto

CFLAGS=$(COPTS) -fobjc-arc
SRCS=acorn2svg.m util.m
HDRS=acorn2svg.h
OBJS=$(SRCS:.m=.o)

acorn2svg: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) -lsqlite3 -framework Foundation -framework AppKit

clean:
	rm -f $(OBJS) acorn2svg

$(OBJS): $(HDRS)

