if ENV["APPRAISAL_INITIALIZED"]
  require 'rails_spec_helper'

  RSpec.describe 'sideload lifecycle hooks', type: :controller do
    class Callbacks
      def self.fired
        @fired
      end

      def self.fired=(val)
        @fired = val
      end
    end

    before do
      Callbacks.fired = {}
    end

    module IntegrationHooks
      class BookResource < JsonapiCompliable::Resource
        type :books
        use_adapter JsonapiCompliable::Adapters::ActiveRecord
        model Book
      end

      class StateResource < JsonapiCompliable::Resource
        type :states
        use_adapter JsonapiCompliable::Adapters::ActiveRecord
        model State
      end

      class AuthorResource < JsonapiCompliable::Resource
        type :authors
        use_adapter JsonapiCompliable::Adapters::ActiveRecord
        model Author

        has_many :books,
          foreign_key: :author_id,
          scope: -> { Book.all },
          resource: BookResource do
            after_save only: [:create] do |author, books|
              Callbacks.fired[:after_create] = [author, books]
            end

            after_save only: [:update] do |author, books|
              Callbacks.fired[:after_update] = [author, books]
            end

            after_save only: [:destroy] do |author, books|
              Callbacks.fired[:after_destroy] = [author, books]
            end

            after_save only: [:disassociate] do |author, books|
              Callbacks.fired[:after_disassociate] = [author, books]
            end

            after_save do |author, books|
              Callbacks.fired[:after_save] = [author, books]
            end
          end

        belongs_to :state,
          foreign_key: :state_id,
          scope: -> { State.all },
          resource: StateResource do
            after_save only: [:create] do |author, states|
              Callbacks.fired[:state_after_create] = [author, states]
            end
          end
      end
    end

    controller(ApplicationController) do
      jsonapi resource: IntegrationHooks::AuthorResource

      def create
        author, success = jsonapi_create.to_a

        if success
          render_jsonapi(author, scope: false)
        else
          raise 'whoops'
        end
      end

      private

      def params
        @params ||= begin
          hash = super.to_unsafe_h.with_indifferent_access
          hash = hash[:params] if hash.has_key?(:params)
          hash
        end
      end
    end

    before do
      @request.headers['Accept'] = Mime[:json]
      @request.headers['Content-Type'] = Mime[:json].to_s

      routes.draw {
        post "create" => "anonymous#create"
      }
    end

    def json
      JSON.parse(response.body)
    end

    let(:update_book) { Book.create! }
    let(:destroy_book) { Book.create! }
    let(:disassociate_book) { Book.create! }

    let(:book_data) { [] }
    let(:book_included) { [] }
    let(:state_data) { nil }
    let(:state_included) { [] }

    let(:payload) do
      {
        data: {
          type: 'authors',
          attributes: { first_name: 'Stephen', last_name: 'King' },
          relationships: {
            books: { data: book_data },
            state: { data: state_data }
          }
        },
        included: (book_included + state_included)
      }
    end

    context 'after_save' do
      before do
        book_data << { :'temp-id' => 'abc123', type: 'books', method: 'create' }
        book_included << { :'temp-id' => 'abc123', type: 'books', attributes: { title: 'one' } }
        book_data << { id: update_book.id.to_s, type: 'books', method: 'update' }
        book_included << { id: update_book.id.to_s, type: 'books', attributes: { title: 'updated!' } }
      end
    end

    context 'after_create' do
      before do
        book_data << { :'temp-id' => 'abc123', type: 'books', method: 'create' }
        book_included << { :'temp-id' => 'abc123', type: 'books', attributes: { title: 'one' } }
        book_data << { :'temp-id' => 'abc456', type: 'books', method: 'create' }
        book_included << { :'temp-id' => 'abc456', type: 'books', attributes: { title: 'two' } }
      end

      it 'fires hooks correctly' do
        post :create, params: payload

        expect(Callbacks.fired.keys).to match_array([:after_create, :after_save])
        author, books = Callbacks.fired[:after_create]
        expect(author).to be_a(Author)
        expect(author.first_name).to eq('Stephen')
        expect(author.last_name).to eq('King')

        expect(books).to all(be_a(Book))
        expect(books.map(&:title)).to match_array(%w(one two))
      end
    end

    context 'after_update' do
      before do
        book_data << { id: update_book.id.to_s, type: 'books', method: 'update' }
        book_included << { id: update_book.id.to_s, type: 'books', attributes: { title: 'updated!' } }
      end

      it 'fires hooks correctly' do
        post :create, params: payload

        expect(Callbacks.fired.keys)
          .to match_array([:after_update, :after_save])
        author, books = Callbacks.fired[:after_update]
        expect(author).to be_a(Author)
        expect(author.first_name).to eq('Stephen')
        expect(author.last_name).to eq('King')

        book = books[0]
        expect(book.title).to eq('updated!')
      end
    end

    context 'after_destroy' do
      before do
        book_data << { id: destroy_book.id.to_s, type: 'books', method: 'destroy' }
      end

      it 'fires hooks correctly' do
        post :create, params: payload

        expect(Callbacks.fired.keys).to match_array([:after_destroy, :after_save])
        author, books = Callbacks.fired[:after_destroy]
        expect(author).to be_a(Author)
        expect(author.first_name).to eq('Stephen')
        expect(author.last_name).to eq('King')

        book = books[0]
        expect(book).to be_a(Book)
        expect(book.id).to eq(destroy_book.id)
        expect { book.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'after_disassociate' do
      before do
        book_data << { id: disassociate_book.id.to_s, type: 'books', method: 'disassociate' }
      end

      it 'fires hooks correctly' do
        post :create, params: payload

        expect(Callbacks.fired.keys).to match_array([:after_disassociate, :after_save])
        author, books = Callbacks.fired[:after_disassociate]
        expect(author).to be_a(Author)
        expect(author.first_name).to eq('Stephen')
        expect(author.last_name).to eq('King')

        book = books[0]
        expect(book).to be_a(Book)
        expect(book.id).to eq(disassociate_book.id)
        expect(book.author_id).to be_nil
      end
    end

    context 'belongs_to' do
      let(:state_data) { { :'temp-id' => 'abc123', type: 'states', method: 'create' } }

      before do
        state_included << { :'temp-id' => 'abc123', type: 'states', attributes: { name: 'New York' } }
      end

      it 'also works' do
        post :create, params: payload
        expect(Callbacks.fired.keys).to match_array([:state_after_create])
        author, states = Callbacks.fired[:state_after_create]
        state = states[0]
        expect(author).to be_a(Author)
        expect(author.first_name).to eq('Stephen')
        expect(author.last_name).to eq('King')
        expect(state).to be_a(State)
        expect(state.name).to eq('New York')
      end
    end
  end
end
