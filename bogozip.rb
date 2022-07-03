#!/usr/bin/env ruby
require 'json'
require 'time'
require 'zlib'

def statproc
	failed = 0
	STDIN.each_line "\0", 65535 do |line|
		path = line.chomp "\0"
		begin
			stat = File.lstat path
			stat.directory? and path[-1] != '/' and path += "/"
			puts({
				mtime: stat.mtime.gmtime.iso8601,
				path: path,
				st_size: stat.size,
				st_mode: stat.mode,
			}.to_json)
		rescue Errno::ENAMETOOLONG, Errno::ENOENT => e
			if line[-1] != "\0"
				warn "#{$0}: #{e.class.new}, find missing -print0?"
				exit failed|2
			else
				warn "#{$0}: #{path}: #{e.class.new}"
				failed |= 1
			end
		end
	end
	exit failed
end

def jqproc
	exec("jq", *ARGV, "-c")
end

def zipproc
	def pack_or_str (s)
		s.respond_to?(:pack) ? s.pack(s[-1]) : s
	end

	failed = 0
	written = 0
	dir = []

	STDIN.each_line 2**20 do |line|
		meta = JSON.parse line, symbolize_names: true rescue {path: line.chomp}

		mtime = meta[:mtime] || 0
		begin
			ts = Time.parse mtime
			mtime = (ts.sec >> 1) + (ts.min << 5) + (ts.hour << 11) +
				(ts.day << 16) + (ts.month << 21) + (ts.year-1980 << 25)
		rescue TypeError
		end

		name = pack_or_str meta[:name] || meta[:path]
		name[-1] == '/' and meta[:content] ||= ""
		meta[:content] ||= File.read pack_or_str meta[:path]

		content = pack_or_str meta[:content]
		crc32 = Zlib.crc32 content

		method, deflated = 0, content
		if meta[:deflate]
			# remove the header and adler32 checksum!
			deflated = Zlib.deflate(content, meta[:deflate])[2..-5]
			method = 8
		end

		extra = ""
		case meta[:extra]
		when Array
			meta[:extra].each do |e|
				extra.concat pack_or_str e
			end
		when String
			extra = meta[:extra]
		end

		comment = pack_or_str meta[:comment]
		comment ||= ""

		langflag = name.bytesize == name.size ? 0 : 2048

		dir.push [
			"PK\1\2", meta[:mode] ? 0x300 : 0, 0, langflag,
			method,
			mtime,
			crc32,
			deflated.bytesize,
			content.bytesize,
			name.bytesize,
			extra.bytesize,
			comment.bytesize,
			0,
			meta[:intattr] || 0,
			(meta[:mode] || 0) << 16,
			written,
			name, extra, comment
		].pack "a*vvvvVVVVvvvvvVVa*a*a*"
		written += STDOUT.write [
			"PK\3\4", 0, langflag,
			method,
			mtime,
			crc32,
			deflated.bytesize,
			content.bytesize,
			name.bytesize,
			extra.bytesize,
			name, extra
		].pack "a*vvvVVVVvva*a*"
		written += STDOUT.write deflated
	end

	dirlen = 0
	dir.each do |ent|
		dirlen += STDOUT.write ent
	end

	if dirlen + written > 0
		STDOUT.write [
			"PK\5\6", 0, 0,
			dir.size,
			dir.size,
			dirlen,
			written,
			0,
			""
		].pack "a*vvvvVVva*"
	else
		failed |= 2
	end

	exit failed
end


zipin, jqout = IO.pipe
zippid = fork {
	jqout.close
	STDIN.reopen(zipin)
	zipin.close
	zipproc
}
zipin.close

jqin, statout = IO.pipe
jqpid = fork {
	statout.close
	STDIN.reopen(jqin)
	jqin.close
	STDOUT.reopen(jqout)
	jqout.close
	jqproc
}
jqout.close
jqin.close

statpid = fork {
	STDOUT.reopen(statout)
	statout.close
	statproc
}
statout.close

status = 0
Process.waitpid statpid
status |= $?.exitstatus << 2
Process.waitpid jqpid
status |= $?.exitstatus
Process.waitpid zippid
status |= $?.exitstatus << 4
exit status
