ArJdbc.load_java_part :Oracle

module ArJdbc
  module Oracle
    
    def self.extended(adapter); initialize!; end
    
    @@_initialized = nil
    
    def self.initialize!
      return if @@_initialized; @@_initialized = true
      
      require 'arjdbc/jdbc/serialized_attributes_helper'
      ActiveRecord::Base.class_eval do
        def after_save_with_oracle_lob
          self.class.columns.select { |c| c.sql_type =~ /LOB\(|LOB$/i }.each do |column|
            value = ::ArJdbc::SerializedAttributesHelper.dump_column_value(self, column)
            next if value.nil? || (value == '')

            self.class.connection.write_large_object(
              column.type == :binary, column.name,
              self.class.table_name, self.class.primary_key, 
              self.class.connection.quote(id), value
            )
          end
        end
      end
      ActiveRecord::Base.after_save :after_save_with_oracle_lob

      unless ActiveRecord::ConnectionAdapters::AbstractAdapter.
          instance_methods(false).detect { |m| m.to_s == "prefetch_primary_key?" }
        require 'arjdbc/jdbc/quoted_primary_key'
        ActiveRecord::Base.extend ArJdbc::QuotedPrimaryKeyExtension
      end
    end
    
    def self.column_selector
      [ /oracle/i, lambda { |cfg, column| column.extend(::ArJdbc::Oracle::Column) } ]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::OracleJdbcConnection
    end

    def jdbc_column_class
      ::ActiveRecord::ConnectionAdapters::OracleColumn
    end

    @@emulate_booleans = true
    
    # Boolean emulation can be disabled using :
    # 
    #   ArJdbc::Oracle.emulate_booleans = false
    # 
    # @see ActiveRecord::ConnectionAdapters::OracleAdapter#emulate_booleans
    def self.emulate_booleans; @@emulate_booleans; end
    def self.emulate_booleans=(emulate); @@emulate_booleans = emulate; end
    
    module Column
      
      def primary=(value)
        super
        @type = :integer if value && @sql_type =~ /^NUMBER$/i
      end
      
      def type_cast(value)
        return nil if value.nil?
        case type
        when :datetime  then Column.string_to_time(value)
        when :timestamp then Column.string_to_time(value)
        when :boolean   then Column.value_to_boolean(value)
        else
          super
        end
      end

      def type_cast_code(var_name)
        case type
        when :datetime  then "ArJdbc::Oracle::Column.string_to_time(#{var_name})"
        when :timestamp then "ArJdbc::Oracle::Column.string_to_time(#{var_name})"
        when :boolean   then "ArJdbc::Oracle::Column.value_to_boolean(#{var_name})"
        else
          super
        end
      end

      # convert a value to a boolean 
      def self.value_to_boolean(value)
        # NOTE: Oracle JDBC meta-data gets us DECIMAL for NUMBER(1) values
        # thus we're likely to get a column back as BigDecimal (e.g. 1.0)
        if value.is_a?(String)
          value.blank? ? nil : value == '1'
        elsif value.is_a?(Numeric)
          value.to_i == 1 # <BigDecimal:7b5bfe,'0.1E1',1(4)>
        else
          !! value
        end
      end
      
      def self.string_to_time(string)
        return string unless string.is_a?(String)
        return nil if string.empty?
        return Time.now if string.index('CURRENT') == 0 # TODO seems very wrong
        
        ::ActiveRecord::ConnectionAdapters::JdbcColumn.string_to_time(string)
      end

      def self.string_to_dummy_time(string)
        ::ActiveRecord::ConnectionAdapters::JdbcColumn.string_to_dummy_time(string)
      end

      def self.guess_date_or_time(value)
        return value if value.is_a? Date
        ( value && value.hour == 0 && value.min == 0 && value.sec == 0 ) ? 
          Date.new(value.year, value.month, value.day) : value
      end

      private
      
      def extract_limit(sql_type)
        case sql_type
        when /^(clob|date)/i then nil
        when /^xml/i then @sql_type = 'XMLTYPE'; nil
        else super
        end
      end
      
      def simplified_type(field_type)
        case field_type
        when /char/i            then :string
        when /float|double/i    then :float
        when /int/i             then :integer
        when /^number\(1\)$/i   then Oracle.emulate_booleans ? :boolean : :integer
        when /^num|dec|real/i   then extract_scale(field_type) == 0 ? :integer : :decimal
        # Oracle TIMESTAMP stores the date and time to up to 9 digits of sub-second precision
        when /TIMESTAMP/i       then :timestamp
        # Oracle DATE stores the date and time to the second
        when /DATE|TIME/i       then :datetime
        when /CLOB/i            then :text
        when /BLOB/i            then :binary
        when /XML/i             then :xml
        else
          super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        return nil unless value
        value = value.strip # Not sure why we need this for Oracle?
        upcase = value.upcase

        return nil if upcase == "NULL"
        # SYSDATE default should be treated like a NULL value
        return nil if upcase == "SYSDATE"
        # jdbc returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/

        value
      end
      
    end
    
    class TableDefinition < ::ActiveRecord::ConnectionAdapters::TableDefinition # :nodoc:
      def raw(*args)
        options = args.extract_options!
        column(args[0], 'raw', options)
      end
      
      def xml(*args)
        options = args.extract_options!
        column(args[0], 'xml', options)
      end
    end
    
    def table_definition(*args)
      new_table_definition(TableDefinition, *args)
    end

    def self.arel2_visitors(config)
      { 'oracle' => Arel::Visitors::Oracle }
    end

    ADAPTER_NAME = 'Oracle'
    
    def adapter_name
      ADAPTER_NAME
    end
    
    NATIVE_DATABASE_TYPES = {
      :primary_key => "NUMBER(38) NOT NULL PRIMARY KEY",
      :string => { :name => "VARCHAR2", :limit => 255 },
      :text => { :name => "CLOB" },
      :integer => { :name => "NUMBER", :limit => 38 },
      :float => { :name => "NUMBER" },
      :decimal => { :name => "DECIMAL" },
      :datetime => { :name => "DATE" },
      :timestamp => { :name => "TIMESTAMP" },
      :time => { :name => "DATE" },
      :date => { :name => "DATE" },
      :binary => { :name => "BLOB" },
      :boolean => { :name => "NUMBER", :limit => 1 },
      :raw => { :name => "RAW", :limit => 2000 },
      :xml => { :name => 'XMLTYPE' }
    }

    def native_database_types
      super.merge(NATIVE_DATABASE_TYPES)
    end
    
    def modify_types(types)
      super(types)
      NATIVE_DATABASE_TYPES.each do |key, value|
        types[key] = value.dup
      end
      types
    end
    
    def prefetch_primary_key?(table_name = nil)
      columns(table_name).detect {|c| c.primary } if table_name
    end

    # Prevent ORA-01795 for in clauses with more than 1000
    def in_clause_length # :nodoc:
      1000
    end
    alias_method :ids_in_list_limit, :in_clause_length
    
    IDENTIFIER_LENGTH = 30 # :nodoc:
    
    # maximum length of Oracle identifiers is 30
    def table_alias_length; IDENTIFIER_LENGTH; end # :nodoc:
    def table_name_length;  IDENTIFIER_LENGTH; end # :nodoc:
    def index_name_length;  IDENTIFIER_LENGTH; end # :nodoc:
    def column_name_length; IDENTIFIER_LENGTH; end # :nodoc:

    def default_sequence_name(table_name, column = nil) # :nodoc:
      "#{table_name.to_s[0, IDENTIFIER_LENGTH - 4]}_seq"
    end

    def create_table(name, options = {}) #:nodoc:
      super(name, options)
      seq_name = options[:sequence_name] || default_sequence_name(name)
      start_value = options[:sequence_start_value] || 10000
      raise ActiveRecord::StatementInvalid.new("name #{seq_name} too long") if seq_name.length > table_alias_length
      execute "CREATE SEQUENCE #{seq_name} START WITH #{start_value}" unless options[:id] == false
    end

    def rename_table(name, new_name) #:nodoc:
      execute "RENAME #{name} TO #{new_name}"
      execute "RENAME #{name}_seq TO #{new_name}_seq" rescue nil
    end

    def drop_table(name, options = {}) #:nodoc:
      super(name) rescue nil
      seq_name = options[:sequence_name] || default_sequence_name(name)
      execute "DROP SEQUENCE #{seq_name}" rescue nil
    end

    def drop_database(name)
      tables.each { |table| drop_table(table) }
    end
    
    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      case type.to_sym
      when :binary
        # { BLOB | BINARY LARGE OBJECT } [ ( length [{K |M |G }] ) ]
        # although Oracle does not like limit (length) with BLOB (or CLOB) :
        # 
        # CREATE TABLE binaries (data BLOB, short_data BLOB(1024));
        # ORA-00907: missing right parenthesis             *
        #
        # TODO do we need to worry about NORMAL vs. non IN-TABLE BLOBs ?!
        # http://dba.stackexchange.com/questions/8770/improve-blob-writing-performance-in-oracle-11g
        # - if the LOB is smaller than 3900 bytes it can be stored inside the 
        #   table row; by default this is enabled, 
        #   unless you specify DISABLE STORAGE IN ROW
        # - normal LOB - stored in a separate segment, outside of table, 
        #   you may even put it in another tablespace;
        super(type, nil, nil, nil)
      when :text
        super(type, nil, nil, nil)
      else
        super
      end
    end
    
    def next_sequence_value(sequence_name)
      # avoid #select or #select_one so that the sequence values aren't cached
      execute("SELECT #{quote_table_name(sequence_name)}.nextval id FROM dual").first['id'].to_i
    end

    def sql_literal?(value)
      defined?(::Arel::SqlLiteral) && ::Arel::SqlLiteral === value
    end

    def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = []) # :nodoc:
      if (id_value && ! sql_literal?(id_value)) || pk.nil?
        # Pre-assigned id or table without a primary key
        # Presence of #to_sql means an Arel literal bind variable
        # that should use #execute_id_insert below
        value = exec_insert(to_sql(sql, binds), name, binds)
        id_value || last_inserted_id(value) # super
      else
        # Assume the sql contains a bind-variable for the id
        # Extract the table from the insert sql. Yuck.
        sequence_name ||= begin
          table = extract_table_ref_from_insert_sql(sql)
          default_sequence_name(table)
        end
        id_value = next_sequence_value(sequence_name)
        log(sql, name) { @connection.execute_id_insert(sql, id_value) }
        id_value
      end
    end
    
    def indexes(table, name = nil)
      @connection.indexes(table, name, @connection.connection.meta_data.user_name)
    end

    def add_limit_offset!(sql, options) #:nodoc:
      offset = options[:offset] || 0

      if limit = options[:limit]
        sql.replace "select * from (select raw_sql_.*, rownum raw_rnum_ from (#{sql}) raw_sql_ where rownum <= #{offset+limit}) where raw_rnum_ > #{offset}"
      elsif offset > 0
        sql.replace "select * from (select raw_sql_.*, rownum raw_rnum_ from (#{sql}) raw_sql_) where raw_rnum_ > #{offset}"
      end
    end

    def current_user # :nodoc:
      @current_user ||= execute("SELECT sys_context('userenv', 'session_user') su FROM dual").first['su']
    end
    
    def current_database # :nodoc:
      @current_database ||= execute("SELECT sys_context('userenv', 'db_name') db FROM dual").first['db']
    end

    def current_schema # :nodoc:
      execute("SELECT sys_context('userenv', 'current_schema') schema FROM dual").first['schema']
    end

    def current_schema=(schema_owner)
      execute("ALTER SESSION SET current_schema=#{schema_owner}")
    end
    
    def create_savepoint # :nodoc:
      execute("SAVEPOINT #{current_savepoint_name}")
    end

    def rollback_to_savepoint # :nodoc:
      execute("ROLLBACK TO #{current_savepoint_name}")
    end

    def release_savepoint # :nodoc:
      # no RELEASE SAVEPOINT statement in Oracle
    end
    
    def remove_index(table_name, options = {}) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      execute "ALTER TABLE #{quote_table_name(table_name)} " + 
        "MODIFY #{quote_column_name(column_name)} DEFAULT #{quote(default)}"
    end

    def add_column_options!(sql, options) #:nodoc:
      # handle case  of defaults for CLOB columns, which would otherwise get "quoted" incorrectly
      if options_include_default?(options) && (column = options[:column]) && column.type == :text
        sql << " DEFAULT #{quote(options.delete(:default))}"
      end
      super
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      change_column_sql = "ALTER TABLE #{quote_table_name(table_name)} " <<
        "MODIFY #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit])}"
      add_column_options!(change_column_sql, options)
      execute(change_column_sql)
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{quote_table_name(table_name)} " <<
        "RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
    end
    
    def remove_column(table_name, *column_names) #:nodoc:
      for column_name in column_names.flatten
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)}"
      end
    end

    def structure_dump #:nodoc:
      s = select_all("SELECT sequence_name FROM user_sequences").inject("") do |structure, seq|
        structure << "CREATE SEQUENCE #{seq.to_a.first.last};\n\n"
      end

      select_all("SELECT table_name FROM user_tables").inject(s) do |structure, table|
        ddl = "CREATE TABLE #{table.to_a.first.last} (\n "
        cols = select_all(%Q{
          SELECT column_name, data_type, data_length, data_precision, data_scale, data_default, nullable
          FROM user_tab_columns
          WHERE table_name = '#{table.to_a.first.last}'
          ORDER by column_id
        }).map do |row|
          row = row.inject({}) { |h, args| h[ args[0].downcase ] = args[1]; h }
          col = "#{row['column_name'].downcase} #{row['data_type'].downcase}"
          if row['data_type'] == 'NUMBER' and ! row['data_precision'].nil?
            col << "(#{row['data_precision'].to_i}"
            col << ",#{row['data_scale'].to_i}" if ! row['data_scale'].nil?
            col << ')'
          elsif row['data_type'].include?('CHAR')
            col << "(#{row['data_length'].to_i})"
          end
          col << " default #{row['data_default']}" if !row['data_default'].nil?
          col << ' not null' if row['nullable'] == 'N'
          col
        end
        ddl << cols.join(",\n ")
        ddl << ");\n\n"
        structure << ddl
      end
    end

    def structure_drop # :nodoc:
      drop = ''
      select_all("SELECT sequence_name FROM user_sequences").inject(drop) do |buff, seq|
        buff << "DROP SEQUENCE #{seq.to_a.first.last};\n\n"
      end
      select_all("SELECT table_name FROM user_tables").inject(drop) do |buff, table|
        buff << "DROP TABLE #{table.to_a.first.last} CASCADE CONSTRAINTS;\n\n"
      end
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # Oracle requires the ORDER BY columns to be in the SELECT list for DISTINCT
    # queries. However, with those columns included in the SELECT DISTINCT list, you
    # won't actually get a distinct list of the column you want (presuming the column
    # has duplicates with multiple values for the ordered-by columns. So we use the
    # FIRST_VALUE function to get a single (first) value for each column, effectively
    # making every row the same.
    #
    #   distinct("posts.id", "posts.created_at desc")
    def distinct(columns, order_by)
      return "DISTINCT #{columns}" if order_by.blank?

      # construct a valid DISTINCT clause, ie. one that includes the ORDER BY columns, using
      # FIRST_VALUE such that the inclusion of these columns doesn't invalidate the DISTINCT
      order_columns = extract_order_columns(order_by).map do |c, i|
        "FIRST_VALUE(#{c.split.first}) OVER (PARTITION BY #{columns} ORDER BY #{c}) AS alias_#{i}__"
      end
      sql = "DISTINCT #{columns}, "
      sql << order_columns * ", "
    end

    # ORDER BY clause for the passed order option.
    #
    # Uses column aliases as defined by {#distinct}.
    def add_order_by_for_association_limiting!(sql, options)
      return sql if options[:order].blank?

      order_columns = extract_order_columns(options[:order]) do |columns|
        columns.map! { |s| $1 if s =~ / (.*)/ }; columns
      end
      order = order_columns.map { |s, i| "alias_#{i}__ #{s}" } # @see {#distinct}

      sql << "ORDER BY #{order.join(', ')}"
    end
    
    def extract_order_columns(order_by)
      columns = order_by.split(',')
      columns.map!(&:strip); columns.reject!(&:blank?)
      columns = yield(columns) if block_given?
      columns.zip( (0...columns.size).to_a )
    end
    private :extract_order_columns
    
    def tables # :nodoc:
      @connection.tables(nil, oracle_schema)
    end
    
    # NOTE: better to use current_schema instead of the configured one ?!
    def columns(table_name, name = nil) # :nodoc:
      @connection.columns_internal(table_name.to_s, nil, oracle_schema)
    end
    
    def tablespace(table_name)
      select_value "SELECT tablespace_name FROM user_tables WHERE table_name='#{table_name.to_s.upcase}'"
    end
    
    # QUOTING ==================================================
    
    def quote_table_name(name) # :nodoc:
      name.to_s.split('.').map{ |n| n.split('@').map{ |m| quote_column_name(m) }.join('@') }.join('.')
    end
    
    def quote_column_name(name) #:nodoc:
      name = name.to_s
      # if only valid lowercase column characters in name
      if name =~ /\A[a-z][a-z_0-9\$#]*\Z/
        # putting double-quotes around an identifier causes Oracle to treat the 
        # identifier as case sensitive (otherwise assumes case-insensitivity) !
        # all upper case is an exception, where double-quotes are meaningless
        "\"#{name.upcase}\"" # name.upcase
      else
        # remove double quotes which cannot be used inside quoted identifier
        "\"#{name.gsub('"', '')}\""
      end
    end
    
    def quote(value, column = nil) # :nodoc:
      return value if sql_literal?(value) # Arel 2 passes SqlLiterals through
      
      column_type = column && column.type
      if column_type == :text || column_type == :binary
        if /(.*?)\([0-9]+\)/ =~ column.sql_type
          %Q{empty_#{ $1.downcase }()}
        else
          %Q{empty_#{ column.sql_type.downcase rescue 'blob' }()}
        end
      elsif column_type == :xml
        "XMLTYPE('#{quote_string(value)}')" # XMLTYPE ?
      elsif column_type == :raw
        quote_raw(value)
      else
        if column.respond_to?(:primary) && column.primary && column.klass != String
          return value.to_i.to_s
        end
        quoted = super
        if value.acts_like?(:date)
          quoted = %Q{DATE'#{quoted_date(value)}'}
        elsif value.acts_like?(:time)
          quoted = %Q{TIMESTAMP'#{quoted_date(value)}'}
        end
        quoted
      end
    end
    
    def quote_raw(value) # :nodoc:
      value = value.unpack('C*') if value.is_a?(String)
      "'#{value.map { |x| "%02X" % x }.join}'"
    end
    
    def supports_migrations? # :nodoc:
      true
    end

    def supports_primary_key? # :nodoc:
      true
    end

    def supports_savepoints? # :nodoc:
      true
    end
    
    def supports_explain? # :nodoc:
      true
    end

    def explain(arel, binds = [])
      sql = "EXPLAIN PLAN FOR #{to_sql(arel)}"
      return if sql =~ /FROM all_/
      execute(sql, 'EXPLAIN', binds)
      select_values("SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)", 'EXPLAIN').join("\n")
    end

    def select(sql, name = nil, binds = [])
      result = super # AR::Result (4.0) or Array (<= 3.2)
      result.columns.delete('raw_rnum_') if result.respond_to?(:columns)
      result.each { |row| row.delete('raw_rnum_') } # Hash rows even for AR::Result
      result
    end
    
    # @override as <code>#execute_insert</code> not working for Oracle e.g.
    # getLong not implemented for class oracle.jdbc.driver.T4CRowidAccessor: 
    # INSERT INTO binaries (data, id, name, short_data) VALUES (?, ?, ?, ?)
    def exec_insert(sql, name, binds, pk = nil, sequence_name = nil) # :nodoc:
      execute(sql, name, binds)
    end
    
    private
    
    def _execute(sql, name = nil)
      if self.class.select?(sql)
        @connection.execute_query_raw(sql)
      else
        @connection.execute_update(sql)
      end
    end
    
    def extract_table_ref_from_insert_sql(sql) # :nodoc:
      table = sql.split(" ", 4)[2].gsub('"', '')
      ( idx = table.index('(') ) ? table[0...idx] : table # INTO table(col1, col2) ...
    end
    
    # In Oracle, schemas are usually created under your username :
    # http://www.oracle.com/technology/obe/2day_dba/schema/schema.htm
    # 
    # A schema is the set of objects (tables, views, indexes, etc) that belongs
    # to an user, often used as another way to refer to an Oracle user account.
    # 
    # But allow separate configuration as "schema:" anyway (see #53)
    def oracle_schema
      if @config[:schema]
        @config[:schema].to_s
      elsif @config[:username]
        @config[:username].to_s
      end
    end

  end
end

module ActiveRecord::ConnectionAdapters
  
  remove_const(:OracleAdapter) if const_defined?(:OracleAdapter)

  class OracleAdapter < JdbcAdapter
    include ::ArJdbc::Oracle
    
    # By default, the MysqlAdapter will consider all columns of type 
    # <tt>tinyint(1)</tt> as boolean. If you wish to disable this :
    #
    #   ActiveRecord::ConnectionAdapters::OracleAdapter.emulate_booleans = false
    #
    def self.emulate_booleans; ::ArJdbc::Oracle.emulate_booleans; end
    def self.emulate_booleans=(emulate); ::ArJdbc::Oracle.emulate_booleans = emulate; end
    
    def initialize(*args)
      ::ArJdbc::Oracle.initialize!
      super # configure_connection happens in super
    end
    
    # some QUOTING caching :

    @@quoted_table_names = {}

    def quote_table_name(name)
      unless quoted = @@quoted_table_names[name]
        quoted = super
        @@quoted_table_names[name] = quoted.freeze
      end
      quoted
    end

    @@quoted_column_names = {}

    def quote_column_name(name)
      unless quoted = @@quoted_column_names[name]
        quoted = super
        @@quoted_column_names[name] = quoted.freeze
      end
      quoted
    end
    
  end

  class OracleColumn < JdbcColumn
    include ::ArJdbc::Oracle::Column
  end
  
end
