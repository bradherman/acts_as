require "acts_as/version"

module ActsAs
  class ActsAs::ActiveRecordOnly < StandardError; end

  PREFIX = %w(id created_at updated_at)

  def self.included(base)
    raise ActiveRecordOnly unless base < ActiveRecord::Base
    base.extend ClassMethods
    base.class_eval do
      alias_method :as_json_without_acted_fields, :as_json
      alias_method :as_json, :as_json_with_acted_fields
    end
  end

  def previous_changes
    self.class.acts_as_fields.keys.map{ |association| send(association).previous_changes }
      .reduce(super) do |current, association_changes|
        current.merge(association_changes)
      end
  end

  def update_column(name, value)
    if (association = self.class.acts_as_fields.detect { |k,v| v.include?(name.to_s) }.try(:first)).present?
      send(association).update_column name, value
    else
      super
    end
  end

  def acts_as_field_match?(method)
    @association_match = self.class.acts_as_fields_match(method)
    @association_match && send(@association_match).respond_to?(method)
  end

  def as_json_with_acted_fields(options = {})
    options[:methods] ||= []
    options[:methods] |= self.class.acts_as_fields.values.flatten
    as_json_without_acted_fields(options)
  end

  module ClassMethods
    def acts_as(association, with: [], prefix: [], **options)
      association_class = (options[:class_name] || association).to_s.camelcase.constantize
      belongs_to(association, **options.merge(autosave: true))
      define_method(association) do |*args|
        unless (acted = instance_variable_get "@acted_#{association}")
          acted = instance_variable_set "@acted_#{association}",
                        ( super(*args) ||
                          (options[:foreign_key] == :id ? association_class.where(id: id).first_or_initialize : nil) ||
                          send("build_#{association}", *args)
                        )
        end
        acted.save if persisted? && acted.new_record?
        acted
      end
      after_create -> { send(association) }

      if association_class.table_exists?
        whitelist_and_delegate_fields(association_class, association, prefix, with)
        override_method_missing
      end
    end

    def acts_as_fields
      @acts_as_fields ||= {}
    end

    def acts_as_fields_match(method)
      acts_as_fields.select do |association, fields|
        fields.select { |f| method.to_s.include?(f) }.any?
      end.keys.first
    end

    def where(opts, *rest)
      return self if opts.blank?
      relation = super
      #TODO support nested attribute joins like Guns.where(rebels: {strength: 10}))
      # for now, only first level joins will happen automagically
      if opts.is_a? Hash
        detected_associations = opts.keys.map {|attr| acts_as_fields_match(attr) }
                                         .reject {|attr| attr.nil?}
        return relation.joins(detected_associations) if detected_associations.any?
      end
      relation
    end

    def expand_hash_conditions_for_aggregates(attrs)
      attrs = super(attrs)
      expanded_attrs = {}

      attrs.each do |attr, value|
        if (association = acts_as_fields_match(attr)) && !self.columns.map(&:name).include?(attr.to_s)
          expanded_attrs[new.send(association).class.table_name] = { attr => value }
        else
          expanded_attrs[attr] = value
        end
      end
      expanded_attrs
    end

    private

    def override_method_missing
      define_method :method_missing do |method, *args, &block|
        if acts_as_field_match?(method)
          send(@association_match).send(method, *args, &block)
        else
          super(method, *args, &block)
        end
      end

      define_method :respond_to? do |method, *args, &block|
        acts_as_field_match?(method) || super(method, *args, &block)
      end
    end

    def whitelist_and_delegate_fields(association_class, one_association, prefix, with)
      association_fields = association_class.columns.map(&:name) - PREFIX - prefix + with

      build_prefix_methods(one_association, prefix)

      attr_accessible *association_fields
      attr_accessible *prefix.map { |field| "#{one_association}_#{field}" }

      delegate(*(association_fields + association_fields.map { |field| "#{field}=" }), to: one_association)

      acts_as_fields[one_association] = association_fields + prefix.map{|field| "#{one_association}_#{field}" }
    end

    def build_prefix_methods(one_association, prefix)
      prefix.each do |field|
        define_method("#{one_association}_#{field}") do |*args|
          send(one_association).send(field, *args)
        end

        define_method("#{one_association}_#{field}=") do |*args|
          send(one_association).send("#{field}=", *args)
        end
      end
    end
  end
end
