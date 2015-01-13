require 'rom/relation_builder'
require 'rom/reader_builder'
require 'rom/command_registry'

require 'rom/env'

module ROM
  class Setup
    # @private
    class Finalize
      attr_reader :repositories, :datasets, :adapter_relation_map

      # @api private
      def initialize(repositories, relations, mappers, commands)
        @repositories = repositories
        @relations = relations
        @mappers = mappers
        @commands = commands
        @datasets = {}
        @adapter_relation_map = {}
      end

      # @api private
      def run!
        load_datasets

        relations = load_relations
        readers = load_readers(relations)
        commands = load_commands(relations)

        Env.new(repositories, relations, readers, commands)
      end

      private

      def load_datasets
        repositories.each do |key, repository|
          datasets[key] = repository.schema
        end
      end

      # @api private
      def load_relations
        relations = {}
        builder = RelationBuilder.new(relations)

        @relations.each do |name, (options, block)|
          relations[name] = build_relation(name, builder, options, block)
        end

        datasets.each do |repository, schema|
          schema.each do |name|
            next if relations.key?(name)
            relations[name] = build_relation(name, builder, repository: repository)
          end
        end

        relations.each_value do |relation|
          relation.class.finalize(relations, relation)
        end

        RelationRegistry.new(relations)
      end

      # @api private
      def build_relation(name, builder, options = {}, block = nil)
        repo_name = options.fetch(:repository) { :default }
        adapter = repositories[repo_name].adapter

        relation = builder.call(name, adapter) do |klass|
          methods = klass.public_instance_methods
          klass.class_eval(&block) if block
          klass.relation_methods = klass.public_instance_methods - methods
        end

        adapter.extend_relation_instance(relation)
        adapter_relation_map[name] = adapter

        relation
      end

      # @api private
      def load_readers(relations)
        return ReaderRegistry.new unless adapter_relation_map.any?

        reader_builder = ReaderBuilder.new(relations)

        readers = @mappers.each_with_object({}) do |(name, options, block), h|
          h[name] = reader_builder.call(name, options, &block)
        end

        ReaderRegistry.new(readers)
      end

      def load_commands(relations)
        return CommandRegistry.new unless adapter_relation_map.any?

        commands = @commands.each_with_object({}) do |(name, definitions), h|
          adapter = adapter_relation_map[name]

          rel_commands = {}

          definitions.each do |command_name, definition|
            rel_commands[command_name] = adapter.command(
              command_name, relations[name], definition
            )
          end

          h[name] = CommandRegistry.new(rel_commands)
        end

        Registry.new(commands)
      end
    end
  end
end