require "numru/narray"
require "tmpdir"
require "erb"

module NumRu
  module NArrayCLoop

    @@tmpnum = 0
    @@verbose = false
    @@omp_opt = nil
    @@header_path = nil  # path of narray.h

    def self.verbose=(bool)
      @@verbose = bool == true
    end

    def self.omp_opt=(opt)
      @@omp_opt = opt
    end

    def self.header_path=(path)
      @@header_path = path
    end

    def self.kernel(*arys,&block)
      @@tmpnum += 1
      na = -1
      args = []
      @@block = Array.new
      @@nest_loop = 0
      @@omp = false
      @@idxmax = 0
      ars = arys.map do |ary|
        na += 1
        vn = "v#{na}"
        args.push vn
        NArrayCLoop::Ary.new(ary.shape, ary.rank, ary.typecode, [:ary, vn], @@block)
      end
      @@body = ""
      self.module_exec(*ars,&block)

      tmpnum = 0
      func_name = "rb_narray_ext_#{@@tmpnum}"
      code = TEMPL_ccode.result(binding)

      sep = "#"*72 + "\n"
      if @@verbose
        print sep
        print "# C source\n"
        print sep
        print code, "\n"
      end

      # save file and compile
#      tmpdir = "tmp"
#      Dir.mkdir(tmpdir) unless File.exist?(tmpdir)
      Dir.mktmpdir(nil, ".") do |tmpdir|
        Dir.chdir(tmpdir) do |dir|
          fname = "narray_ext_#{@@tmpnum}.c"
          File.open(fname, "w") do |file|
            file.print code
          end
          extconf = TEMPL_extconf.result(binding)
          File.open("extconf.rb", "w") do |file|
            file.print extconf
          end
          unless system("ruby extconf.rb > log 2>&1")
            print sep, "# LOG (ruby extconf.rb)\n"
            print sep, File.read("log"), "\n"

            print sep, "# extconf.rb\n"
            print sep, extconf, "\n"

            print sep, "# mkmf.log\n"
            print sep, File.read("mkmf.log"), "\n"

            print sep, "\n"
            raise("extconf error")
          end
          unless system("make > log 2>&1")
            print sep, "# LOG (make)\n"
            print sep, File.read("log"), "\n"

            print sep, "# C source (#{fname})\n"
            print sep, File.read(fname), "\n"

            print "\n"
            raise("compile error")
          end
          if @@verbose
            print sep, "# compile\n"
            print sep, File.read("log"), "\n"
            print sep, "# execute\n"
            print sep
            print <<EOF
require "./narray_ext_#{@@tmpnum}.so"
NumRu::NArrayCLoop.send("c_func_#{@@tmpnum}", #{(0...arys.length).to_a.map{|i| "v#{i}"}.join(", ")})

EOF
          end

          # execute
          require "./narray_ext_#{@@tmpnum}.so"
          NumRu::NArrayCLoop.send("c_func_#{@@tmpnum}", *arys)
        end
      end

      return nil
    end


    def self.c_loop(min, max, openmp=false)
      @@omp ||= openmp
      i = @@block.length
      @@idxmax = [@@idxmax, @@nest_loop+1].max
      idx = NArrayCLoop::Index.new(@@nest_loop, min, max)
      @@body << "#pragma omp parallel for\n" if openmp
      @@body << "  "*(@@nest_loop+1)
      @@body << "for (i#{@@nest_loop}=#{min}; i#{@@nest_loop}<=#{max}; i#{@@nest_loop}++) {\n"

      @@block.push Array.new
      @@nest_loop += 1
      yield(idx)
      offset = "  "*(i+2)
      @@block.pop.each do |ex|
        @@body << offset
        @@body << (String===ex ? ex : ex.to_c)
        @@body << ";\n"
      end
      @@body << "  "*(i+1)+"}\n"
      @@nest_loop -= 1
    end

    def self.c_if(cond)
      i = @@block.length
      if i==0
        raise "cif must be in a loop"
      end
      @@body << "  "*(@@block.length+1)
      @@body << "if ( #{cond.to_c} ) {\n"

      @@block.push Array.new
      yield
      offset = "  "*(i+2)
      @@block.pop.each do |ex|
        @@body << offset
        @@body << (String===ex ? ex : ex.to_c)
        @@body << ";\n"
      end
      @@body << "  "*(i+1)+"}\n"
    end



    class Index

      def initialize(idx,min,max,shift=nil)
        @idx = idx
        @min = min
        @max = max
        @shift = shift
      end

      def +(i)
        case i
        when Fixnum
          NArrayCLoop::Index.new(@idx,@min,@max,i)
        else
          raise ArgumentError, "invalid argument"
        end
      end

      def -(i)
        case i
        when Fixnum
          NArrayCLoop::Index.new(@idx,@min,@max,-i)
        else
          raise ArgumentError, "invalid argument"
        end
      end

      def to_s
        if @shift.nil?
          "i#{@idx}"
        elsif @shift > 0
          "i#{@idx}+#{@shift}"
        else # < 0
          "i#{@idx}#{@shift}"
        end
      end
      alias :inspect :to_s

      def idx
        @idx
      end
      def min
        @shift ? [@min, @min+@shift].min : @min
      end
      def max
        @shift ? [@max, @max+@shift].max : @max
      end

    end


    class Ary

      @@ntype2ctype = {NArray::BYTE => "u_int8_t*",
                       NArray::SINT => "int16_t*",
                       NArray::LINT => "int32_t*",
                       NArray::SFLOAT => "float*",
                       NArray::DFLOAT => "double*",
                       NArray::SCOMPLEX => "scomplex*",
                       NArray::DCOMPLEX => "dcomplex*"}
      if NArray.const_defined?(:LLINT)
        @@ntype2ctype[NArray::LLINT] = "int64_t*"
      end

      def initialize(shape, rank, type, ops, exec=nil)
        @shape = shape
        @rank = rank
        @type = type
        @ops = ops
        @exec = exec
        if @type==NArray::SCOMPLEX || @type==NArray::DCOMPLEX
          raise "complex is not supported at this moment"
        end
      end

      def [](*idx)
        unless idx.length == @rank
          raise "number of idx != rank"
        end
        self.class.new(@shape, 0, @type, [:slice, @ops, slice(*idx)], @exec)
      end

      def []=(*arg)
        idx = arg[0..-2]
        other = arg[-1]
        unless idx.length == @rank
          raise "number of idx != rank"
        end
        ops = [:slice, @ops, slice(*idx)]
        case other
        when Numeric
          @exec[-1].push self.class.new(@shape, @rank, @type, [:set, ops, [:int,other]])
        when self.class
          @exec[-1].push self.class.new(@shape, @rank, @type, [:set, ops, other.ops])
        else
          raise ArgumentError, "invalid argument"
        end
        return nil
      end

      [
        ["+", "add"],
        ["-", "sub"],
        ["*", "mul"],
        ["/", "div"],
        [">",  "gt"],
        [">=", "ge"],
        ["<",  "lt"],
        ["<=", "le"]
      ].each do |m, op|
        str = <<EOF
      def #{m}(other)
        binary_operation(other, :#{op})
      end
EOF
        eval str
      end

      def to_c
        get_str(@ops)
      end

      def ctype
        @@ntype2ctype[@type]
      end

      protected
      def ops
        @ops
      end

      @@twoop = {:add => "+", :sub => "-", :mul => "*", :div => "/", :set => "="}
      @@compop = {:gt => ">", :ge => ">=", :lt => "<", :le => "<="}

      private
      def get_str(obj)
        op = obj[0]
        obj = obj[1..-1]
        case op
        when :slice
          obj, idx = obj
          obj = get_str(obj)
          return "#{obj}[#{idx}]"
        when :add, :sub, :mul, :div
          o1, o2 = obj
          o1 = get_str(o1)
          o2 = get_str(o2)
          return "( #{o1} #{@@twoop[op]} #{o2} )"
        when :set
          o1, o2 = obj
          o1 = get_str(o1)
          o2 = get_str(o2)
          return "#{o1} #{@@twoop[op]} #{o2}"
        when :int, :ary
          return obj[0].to_s
        when :gt, :ge, :lt, :le
          o1, o2 = obj
          o1 = get_str(o1)
          o2 = get_str(o2)
          return "#{o1} #{@@compop[op]} #{o2}"
        else
          raise "unexpected value: #{op} (#{op.class})"
        end
      end

      def binary_operation(other, op)
        unless @rank==0
          raise "slice first"
        end
        case other
        when Numeric
          return self.class.new(@shape, 0, @type, [op, @ops, [:int,other]], @exec)
        when self.class
          return self.class.new(@shape, 0, @type, [op, @ops, other.ops], @exec)
        else
          raise ArgumentError, "invalid argument: #{other} (#{other.class})"
        end
      end

      def slice(*idx)
        case @rank
        when 0
          raise "rank is zero"
        else
          unless Array===idx && idx.length == @rank
            raise ArgumentError, "number of index must be equal to rank"
          end
        end
        idx.each_with_index do |id,i|
          case id
          when NArrayCLoop::Index
            if id.min < 0 || id.max > @shape[i]-1
              raise ArgumentError, "out of boundary"
            end
          when Fixnum
            idx[i] = id + @shape[i] if id < 0
            if id > @shape[i]-1
              raise ArgumentError, "out of boundary"
            end
          else
            raise ArgumentError, "index is invalid: #{id} (#{id.class}) #{@rank}"
          end
        end
        if @rank == 1
          sidx = idx[0].to_s
        else
          sidx = idx[-1].to_s
          (@rank-1).times do |i|
            sidx = "(#{sidx})*#{@shape[-i-2]}+(#{idx[-i-2].to_s})"
          end
        end
        return sidx
      end

    end # class Ary



    # templates

    TEMPL_ccode = ERB.new <<EOF
#include "ruby.h"
#include "narray.h"

VALUE
<%= func_name %>(VALUE self, VALUE rb_<%= args.join(", VALUE rb_") %>) {
<% ars.each_with_index do |ary,i| %>
<%   ctype = ary.ctype %>
  <%= ctype %> v<%= i %> = NA_PTR_TYPE(rb_v<%= i %>, <%= ctype %>);
<% end %>
<% @@idxmax.times do |i| %>
  int i<%= i %>;
<% end %>
<%= @@body %>

  return Qnil;
}

void
Init_narray_ext_<%= @@tmpnum %>()
{
  VALUE mNumRu = rb_define_module("NumRu");
  VALUE mNArrayCLoop = rb_define_module_under(mNumRu, "NArrayCLoop");
  rb_define_module_function(mNArrayCLoop, "c_func_<%= @@tmpnum %>", <%= func_name %>, <%= ars.length %>);
}
EOF


    TEMPL_extconf = ERB.new <<EOF
require "mkmf"
<% if @@header_path %>
header_path = "<%= @@header_path %>"
<% else %>
require "rubygems"
gem_path = nil
if Gem::Specification.respond_to?(:find_by_name)
  if spec = Gem::Specification.find_by_name("numru-narray")
    gem_path = spec.full_gem_path
  end
else
  if spec = Gem.source_index.find_name("numru-narray").any?
    gem_path = spec.full_gem_path
  end
end
unless gem_path
  raise "gem numru-narray not found"
end
header_path = File.join(gem_path, "ext", "numru", "narray")
<% end %>

find_header("narray_config.h", *([header_path]+Dir["../tmp/*/narray/*"]))
unless find_header("narray.h", header_path)
  STDERR.print "narray.h not found\n"
  STDERR.print "Set path of narray.h to NumRu::NArrayCLoop.header_path\n"
  raise "narray.h not found"
end

# openmp enable
<% if @@omp %>
<%   if @@omp_opt %>
omp_opt = <%= @@omp_opt %>
<%   else %>
case RbConfig::CONFIG["CC"]
when "gcc"
  omp_opt = "-fopenmp"
else
  omp_opt = nil
end
<%   end %>
if omp_opt
  $CFLAGS << " " << omp_opt
  $DLDFLAGS << " " << omp_opt
else
  warn "openmp is disabled (Set compiler option for OpenMP to NArrayCLoop.omp_opt"
end
<% else %>
warn "openmp is disabled"
<% end %>

create_makefile("narray_ext_<%= @@tmpnum %>")
EOF


  end # module NArrayCLoop

end # module NumRu
