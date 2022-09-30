require 'webmock/rspec'
require 'rails_helper'
RSpec.describe Webui::PackageController, vcr: true do
  let(:admin) { create(:admin_user, login: 'admin') }
  let(:user) { create(:confirmed_user, :with_home, login: 'tom') }
  let(:source_project) { user.home_project }
  let(:source_package) { create(:package, name: 'my_package', project: source_project) }
  let(:target_project) { create(:project) }
  let(:package) { create(:package_with_file, name: 'package_with_file', project: source_project) }
  let(:service_package) { create(:package_with_service, name: 'package_with_service', project: source_project) }
  let(:broken_service_package) { create(:package_with_broken_service, name: 'package_with_broken_service', project: source_project) }
  let(:repo_for_source_project) do
    repo = create(:repository, project: source_project, architectures: ['i586'], name: 'source_repo')
    source_project.store(login: user)
    repo
  end
  let(:fake_build_results) do
    <<-HEREDOC
      <resultlist state=\"2b71f05ecb8742e3cd7f6066a5097c72\">
        <result project=\"home:tom\" repository=\"#{repo_for_source_project.name}\" arch=\"x86_64\"
          code=\"unknown\" state=\"unknown\" dirty=\"true\">
         <binarylist>
            <binary filename=\"image_binary.vhdfixed.xz\" size=\"123312217\"/>
            <binary filename=\"image_binary.xz.sha256\" size=\"1531\"/>
            <binary filename=\"_statistics\" size=\"4231\"/>
            <binary filename=\"updateinfo.xml\" size=\"4231\"/>
            <binary filename=\"rpmlint.log\" size=\"121\"/>
          </binarylist>
        </result>
      </resultlist>
    HEREDOC
  end
  let(:fake_build_results_without_binaries) do
    <<-HEREDOC
      <resultlist state="2b71f05ecb8742e3cd7f6066a5097c72">
        <result project="home:tom" repository="fake_repo_name" arch="i586" code="unknown" state="unknown" dirty="true">
         <binarylist>
          </binarylist>
        </result>
      </resultlist>
    HEREDOC
  end

  describe 'POST #save' do
    before do
      login(user)
    end

    context 'valid data' do
      before do
        post :save, params: {
          project: source_project, package: source_package, title: 'New title for package', description: 'New description for package'
        }
      end

      it { expect(flash[:success]).to eq("Package data for '#{source_package.name}' was saved successfully") }
      it { expect(source_package.reload.title).to eq('New title for package') }
      it { expect(source_package.reload.description).to eq('New description for package') }
      it { expect(response).to redirect_to(package_show_path(project: source_project, package: source_package)) }
    end

    context 'invalid data' do
      before do
        post :save, params: {
          project: source_project, package: source_package, title: 'New title for package', description: SecureRandom.hex(32_768) # = 65536 chars
        }
      end

      it { expect(controller).to set_flash[:error] }
      it { expect(response).to redirect_to(package_show_path(project: source_project, package: source_package)) }
    end
  end

  describe 'GET #meta' do
    before do
      get :meta, params: { project: source_project, package: source_package }
    end

    it 'sends the xml representation of a package' do
      expect(assigns(:meta)).to eq(source_package.render_xml)
    end

    it { expect(response).to render_template('package/meta') }
    it { expect(response).to have_http_status(:success) }
  end

  describe 'POST #remove' do
    before do
      login(user)
    end

    describe 'authentication' do
      let(:target_package) { create(:package, name: 'forbidden_package', project: target_project) }

      it 'does not allow other users than the owner to delete a package' do
        post :remove, params: { project: target_project, package: target_package }

        expect(flash[:error]).to eq('Sorry, you are not authorized to delete this package.')
        expect(target_project.packages).not_to be_empty
      end

      it "allows admins to delete other user's packages" do
        login(admin)
        post :remove, params: { project: target_project, package: target_package }

        expect(flash[:success]).to eq('Package was successfully removed.')
        expect(target_project.packages).to be_empty
      end
    end

    context 'a package' do
      before do
        post :remove, params: { project: user.home_project, package: source_package }
      end

      it { expect(response).to have_http_status(:found) }
      it { expect(flash[:success]).to eq('Package was successfully removed.') }

      it 'deletes the package' do
        expect(user.home_project.packages).to be_empty
      end
    end

    context 'a package with dependencies' do
      let(:devel_project) { create(:package, project: target_project) }

      before do
        source_package.develpackages << devel_project
      end

      it 'does not delete the package and shows an error message' do
        post :remove, params: { project: user.home_project, package: source_package }

        expect(flash[:error]).to eq("Package can't be removed: used as devel package by #{target_project}/#{devel_project}")
        expect(user.home_project.packages).not_to be_empty
      end

      context 'forcing the deletion' do
        before do
          post :remove, params: { project: user.home_project, package: source_package, force: true }
        end

        it 'deletes the package' do
          expect(flash[:success]).to eq('Package was successfully removed.')
          expect(user.home_project.packages).to be_empty
        end
      end
    end
  end

  describe 'GET #show' do
    context 'require_package before_action' do
      context 'with an invalid package' do
        it { expect { get :show, params: { project: user.home_project, package: 'no_package' } }.to raise_error(ActiveRecord::RecordNotFound) }
      end
    end

    context 'with a valid package' do
      before do
        get :show, params: { project: user.home_project, package: source_package.name }
      end

      it 'assigns @package' do
        expect(assigns(:package)).to eq(source_package)
      end
    end

    context 'with a package that has a broken service' do
      before do
        login user
        get :show, params: { project: user.home_project, package: broken_service_package.name }
      end

      it { expect(flash[:error]).to include('Files could not be expanded:') }
      it { expect(assigns(:more_info)).to include('service daemon error:') }
    end

    context 'with a package without sourceaccess' do
      before do
        create(:sourceaccess_flag, project: user.home_project)
        get :show, params: { project: user.home_project, package: source_package.name }
      end

      it { expect(flash[:error]).to eq("You don't have access to the sources of this package: \"#{source_package}\"") }
      it { expect(response).to redirect_to(project_show_path(user.home_project)) }
    end

    context 'revision handling' do
      let(:package_with_revisions) do
        create(:package_with_revisions, name: 'rev_package', revision_count: 3, project: user.home_project)
      end

      after do
        # Cleanup: otherwhise older revisions stay in backend and influence other tests, and test re-runs
        package_with_revisions.destroy
      end

      context "with a 'rev' parameter with existent revision" do
        before do
          get :show, params: { project: user.home_project, package: package_with_revisions, rev: 2 }
        end

        it { expect(assigns(:revision)).to eq('2') }
        it { expect(response).to have_http_status(:success) }
      end

      context "with a 'rev' parameter with non-existent revision" do
        before do
          get :show, params: { project: user.home_project, package: package_with_revisions, rev: 4 }
        end

        it { expect(flash[:error]).to eq('No such revision: 4') }
        it { expect(response).to redirect_to(package_show_path(project: user.home_project, package: package_with_revisions)) }
      end
    end
  end

  describe 'DELETE #remove_file' do
    before do
      login(user)
      allow_any_instance_of(Package).to receive(:delete_file).and_return(true)
    end

    def remove_file_post
      post :remove_file, params: { project: user.home_project, package: source_package, filename: 'the_file' }
    end

    context 'with successful backend call' do
      before do
        remove_file_post
      end

      it { expect(flash[:success]).to eq("File 'the_file' removed successfully") }
      it { expect(assigns(:package)).to eq(source_package) }
      it { expect(assigns(:project)).to eq(user.home_project) }
      it { expect(response).to redirect_to(package_show_path(project: user.home_project, package: source_package)) }
    end

    context 'with not successful backend call' do
      before do
        allow_any_instance_of(Package).to receive(:delete_file).and_raise(Backend::NotFoundError)
        remove_file_post
      end

      it { expect(flash[:error]).to eq("Failed to remove file 'the_file'") }
    end

    it 'calls delete_file method' do
      allow_any_instance_of(Package).to receive(:delete_file).with('the_file')
      remove_file_post

      expect(flash[:success]).to eq("File 'the_file' removed successfully")
    end

    context 'with no permissions' do
      let(:other_user) { create(:confirmed_user) }

      before do
        login other_user
        remove_file_post
      end

      it { expect(flash[:error]).to eq('Sorry, you are not authorized to update this package.') }
      it { expect(Package.where(name: 'my_package')).to exist }
    end
  end

  describe 'GET #revisions' do
    let(:project) { create(:project, maintainer: user, name: 'some_dev_project123') }
    let(:package) { create(:package_with_revisions, name: 'package_with_one_revision', revision_count: 1, project: project) }
    let(:elided_package_name) { 'package_w...revision' }

    before do
      login(user)
    end

    context 'without source access' do
      before do
        package.add_flag('sourceaccess', 'disable')
        package.save
        get :revisions, params: { project: project, package: package }
      end

      it { expect(flash[:error]).to eq("You don't have access to the sources of this package: \"#{elided_package_name}\"") }
      it { expect(response).to redirect_to(project_show_path(project: project.name)) }
    end

    context 'with source access' do
      before do
        get :revisions, params: { project: project, package: package }
      end

      after do
        # Delete revisions that got created in the backend
        package.destroy
      end

      it 'sets the project' do
        expect(assigns(:project)).to eq(project)
      end

      it 'sets the package' do
        expect(assigns(:package)).to eq(package)
      end

      context 'when not passing the rev parameter' do
        let(:package_with_revisions) { create(:package_with_revisions, name: "package_with_#{revision_count}_revisions", revision_count: revision_count, project: project) }
        let(:revision_count) { 25 }

        before do
          get :revisions, params: { project: project, package: package_with_revisions }
        end

        after do
          # Delete revisions that got created in the backend
          package_with_revisions.destroy
        end

        it 'returns revisions with the default pagination' do
          expect(assigns(:revisions)).to eq((6..revision_count).to_a.reverse)
        end

        context 'and passing the show_all parameter' do
          before do
            get :revisions, params: { project: project, package: package_with_revisions, show_all: 1 }
          end

          it 'returns revisions without pagination' do
            expect(assigns(:revisions)).to eq((1..revision_count).to_a.reverse)
          end
        end

        context 'and passing the page parameter' do
          before do
            get :revisions, params: { project: project, package: package_with_revisions, page: 2 }
          end

          it "returns the paginated revisions for the page parameter's value" do
            expect(assigns(:revisions)).to eq((1..5).to_a.reverse)
          end
        end
      end

      context 'when passing the rev parameter' do
        before do
          get :revisions, params: { project: project, package: package, rev: param_rev }
        end

        let(:param_rev) { 23 }

        it "returns revisions up to rev parameter's value with the default pagination" do
          expect(assigns(:revisions)).to eq((4..param_rev).to_a.reverse)
        end

        context 'and passing the show_all parameter' do
          before do
            get :revisions, params: { project: project, package: package, rev: param_rev, show_all: 1 }
          end

          it "returns revisions up to rev parameter's value without pagination" do
            expect(assigns(:revisions)).to eq((1..param_rev).to_a.reverse)
          end
        end

        context 'and passing the page parameter' do
          before do
            get :revisions, params: { project: project, package: package, rev: param_rev, page: 2 }
          end

          it "returns the paginated revisions for the page parameter's value" do
            expect(assigns(:revisions)).to eq((1..3).to_a.reverse)
          end
        end
      end
    end
  end

  describe 'GET #trigger_services' do
    before do
      login user
    end

    context 'with right params' do
      let(:post_url) { "#{CONFIG['source_url']}/source/#{source_project}/#{service_package}?cmd=runservice&user=#{user}" }

      before do
        get :trigger_services, params: { project: source_project, package: service_package }
      end

      it { expect(a_request(:post, post_url)).to have_been_made.once }
      it { expect(flash[:success]).to eq('Services successfully triggered') }
      it { is_expected.to redirect_to(action: :show, project: source_project, package: service_package) }
    end

    context 'without a service file in the package' do
      let(:package) { create(:package_with_file, name: 'package_with_file', project: source_project) }
      let(:post_url) { "#{CONFIG['source_url']}/source/#{source_project}/#{package}?cmd=runservice&user=#{user}" }

      before do
        get :trigger_services, params: { project: source_project, package: package }
      end

      it { expect(a_request(:post, post_url)).to have_been_made.once }
      it { expect(flash[:error]).to eq("Services couldn't be triggered: no source service defined!") }
      it { is_expected.to redirect_to(action: :show, project: source_project, package: package) }
    end

    context 'without permissions' do
      let(:post_url) { %r{#{CONFIG['source_url']}/source/#{source_project}/#{service_package}\.*} }
      let(:other_user) { create(:confirmed_user) }

      before do
        login other_user
        get :trigger_services, params: { project: source_project, package: package }
      end

      it { expect(a_request(:post, post_url)).not_to have_been_made }
      it { expect(flash[:error]).to eq('Sorry, you are not authorized to update this package.') }
      it { is_expected.to redirect_to(root_path) }
    end
  end

  describe 'POST #save_meta' do
    let(:valid_meta) do
      "<package name=\"#{source_package.name}\" project=\"#{source_project.name}\">" \
        '<title>My Test package Updated via Webui</title><description/></package>'
    end

    let(:invalid_meta_because_package_name) do
      "<package name=\"whatever\" project=\"#{source_project.name}\">" \
        '<title>Invalid meta PACKAGE NAME</title><description/></package>'
    end

    let(:invalid_meta_because_project_name) do
      "<package name=\"#{source_package.name}\" project=\"whatever\">" \
        '<title>Invalid meta PROJECT NAME</title><description/></package>'
    end

    let(:invalid_meta_because_xml) do
      "<package name=\"#{source_package.name}\" project=\"#{source_project.name}\">" \
        '<title>Invalid meta WRONG XML</title><description/></paaaaackage>'
    end

    before do
      login user
    end

    context 'with proper params' do
      before do
        post :save_meta, params: { project: source_project, package: source_package, meta: valid_meta }
      end

      it { expect(flash[:success]).to eq('The Meta file has been successfully saved.') }
      it { expect(response).to have_http_status(:ok) }
    end

    context 'without admin rights to raise protection level' do
      before do
        allow_any_instance_of(Package).to receive(:disabled_for?).with('sourceaccess', nil, nil).and_return(false)
        allow(FlagHelper).to receive(:xml_disabled_for?).with(Xmlhash.parse(valid_meta), 'sourceaccess').and_return(true)

        post :save_meta, params: { project: source_project, package: source_package, meta: valid_meta }
      end

      it { expect(flash[:error]).to eq('Error while saving the Meta file: admin rights are required to raise the protection level of a package.') }
      it { expect(response).to have_http_status(:bad_request) }
    end

    context 'with an invalid package name' do
      before do
        post :save_meta, params: { project: source_project, package: source_package, meta: invalid_meta_because_package_name }
      end

      it { expect(flash[:error]).to eq('Error while saving the Meta file: package name in xml data does not match resource path component.') }
      it { expect(response).to have_http_status(:bad_request) }
    end

    context 'with an invalid project name' do
      before do
        post :save_meta, params: { project: source_project, package: source_package, meta: invalid_meta_because_project_name }
      end

      it { expect(flash[:error]).to eq('Error while saving the Meta file: project name in xml data does not match resource path component.') }
      it { expect(response).to have_http_status(:bad_request) }
    end

    context 'with invalid XML' do
      before do
        post :save_meta, params: { project: source_project, package: source_package, meta: invalid_meta_because_xml }
      end

      it do
        expect(flash[:error]).to match(/Error while saving the Meta file: package validation error.*FATAL:/)
        expect(flash[:error]).to match(/Opening and ending tag mismatch: package line 1 and paaaaackage\./)
      end

      it { expect(response).to have_http_status(:bad_request) }
    end

    context 'with an unexistent package' do
      let(:post_save_meta) { post :save_meta, params: { project: source_project, package: 'blah', meta: valid_meta } }

      it { expect { post_save_meta }.to raise_error(ActiveRecord::RecordNotFound) }
    end

    context 'when connection with the backend fails' do
      before do
        allow_any_instance_of(Package).to receive(:update_from_xml).and_raise(Backend::Error, 'fake message')

        post :save_meta, params: { project: source_project, package: source_package, meta: valid_meta }
      end

      it { expect(flash[:error]).to eq('Error while saving the Meta file: fake message.') }
      it { expect(response).to have_http_status(:bad_request) }
    end

    context 'when not found the User or Group' do
      before do
        allow_any_instance_of(Package).to receive(:update_from_xml).and_raise(NotFoundError, 'fake message')

        post :save_meta, params: { project: source_project, package: source_package, meta: valid_meta }
      end

      it { expect(flash[:error]).to eq('Error while saving the Meta file: fake message.') }
      it { expect(response).to have_http_status(:bad_request) }
    end
  end

  describe 'GET #rdiff' do
    context 'when no difference in sources diff is empty' do
      before do
        login user
        get :rdiff, params: { project: source_project, package: package, oproject: source_project, opackage: package }
      end

      it { expect(assigns[:filenames]).to be_empty }
    end

    context 'when an empty revision is provided' do
      before do
        login user
        get :rdiff, params: { project: source_project, package: package, rev: '' }
      end

      it { expect(flash[:error]).to eq('Error getting diff: revision is empty') }
      it { is_expected.to redirect_to(package_show_path(project: source_project, package: package)) }
    end

    context 'with diff truncation' do
      let(:diff_header_size) { 4 }
      let(:ascii_file_size) { 11_000 }
      # Taken from package_with_binary_diff factory files (bigfile_archive.tar.gz and bigfile_archive_2.tar.gz)
      let(:binary_file_size) { 30_000 }
      let(:binary_file_changed_size) { 13_000 }
      # TODO: check if this value, the default diff size, is correct
      let(:default_diff_size) { 199 }
      let(:package_ascii_file) do
        create(:package_with_file, name: 'diff-truncation-test-1', project: source_project, file_content: "a\n" * ascii_file_size)
      end
      let(:package_binary_file) { create(:package_with_binary_diff, name: 'diff-truncation-test-2', project: source_project) }

      context 'full diff requested' do
        it 'does not show a hint' do
          login user
          get :rdiff, params: { project: source_project, package: package_ascii_file, full_diff: true, rev: 2 }
          expect(assigns(:not_full_diff)).to be_falsy
        end

        context 'for ASCII files' do
          before do
            login user
            get :rdiff, params: { project: source_project, package: package_ascii_file, full_diff: true, rev: 2 }
          end

          it 'shows the complete diff' do
            diff_size = assigns(:files)['somefile.txt']['diff']['_content'].split.size
            expect(diff_size).to eq(ascii_file_size + diff_header_size)
          end
        end

        context 'for archives' do
          before do
            login user
            get :rdiff, params: { project: source_project, package: package_binary_file, full_diff: true }
          end

          it 'shows the complete diff' do
            diff = assigns(:files)['bigfile_archive.tar.gz/bigfile.txt']['diff']['_content'].split("\n")
            expect(diff).to eq(['@@ -1,6 +1,6 @@', '-a', '-a', '-a', '-a', '-a', '-a', '+b', '+b', '+b', '+b', '+b', '+b'])
          end
        end
      end

      context 'full diff not requested' do
        it 'shows a hint' do
          login user
          get :rdiff, params: { project: source_project, package: package_ascii_file, rev: 2 }
          expect(assigns(:not_full_diff)).to be_truthy
        end

        context 'for ASCII files' do
          before do
            login user
            get :rdiff, params: { project: source_project, package: package_ascii_file, rev: 2 }
          end

          it 'shows the truncated diff' do
            diff_size = assigns(:files)['somefile.txt']['diff']['_content'].split.size
            expect(diff_size).to eq(default_diff_size + diff_header_size)
          end
        end

        context 'for archives' do
          before do
            login user
            get :rdiff, params: { project: source_project, package: package_binary_file }
          end

          it 'shows the truncated diff' do
            diff = assigns(:files)['bigfile_archive.tar.gz/bigfile.txt']['diff']['_content'].split("\n")
            expect(diff).to eq(['@@ -1,6 +1,6 @@', '-a', '-a', '-a', '-a', '-a', '-a', '+b', '+b', '+b', '+b', '+b', '+b'])
          end
        end
      end
    end
  end

  context 'build logs' do
    let(:source_project_with_plus) { create(:project, name: 'foo++bar') }
    let(:package_of_project_with_plus) { create(:package, name: 'some_package', project: source_project_with_plus) }
    let(:source_package_with_plus) { create(:package, name: 'my_package++special', project: source_project) }
    let(:repo_leap_42_2) { create(:repository, name: 'leap_42.2', project: source_project, architectures: ['i586']) }
    let(:architecture) { repo_leap_42_2.architectures.first }

    RSpec.shared_examples 'build log' do
      before do
        repo_leap_42_2
        source_project.store(login: user)
      end

      context 'successfully' do
        before do
          path = "#{CONFIG['source_url']}/build/#{user.home_project}/_result?arch=i586" \
                 "&package=#{source_package}&repository=#{repo_leap_42_2}&view=status"
          stub_request(:get, path).and_return(body:
            %(<resultlist state='123'>
               <result project='#{user.home_project}' repository='#{repo_leap_42_2}' arch='i586'>
                 <binarylist/>
               </result>
              </resultlist>))
          do_request project: source_project, package: source_package, repository: repo_leap_42_2.name, arch: 'i586', format: 'js'
        end

        it { expect(response).to have_http_status(:ok) }
      end

      context "successfully with a package which name that includes '+'" do
        before do
          path = "#{CONFIG['source_url']}/build/#{user.home_project}/_result?arch=i586" \
                 "&package=#{source_package_with_plus}&repository=#{repo_leap_42_2}&view=status"
          stub_request(:get, path).and_return(body:
            %(<resultlist state='123'>
               <result project='#{user.home_project}' repository='#{repo_leap_42_2}' arch='i586'>
                 <binarylist/>
               </result>
              </resultlist>))
          do_request project: source_project, package: source_package_with_plus, repository: repo_leap_42_2.name, arch: 'i586', format: 'js'
        end

        it { expect(response).to have_http_status(:ok) }
      end

      context "successfully with a project which name that includes '+'" do
        let(:repo_leap_45_1) { create(:repository, name: 'leap_45.1', project: source_project_with_plus, architectures: ['i586']) }

        before do
          repo_leap_45_1
          source_project_with_plus.store

          path = "#{CONFIG['source_url']}/build/#{source_project_with_plus}/_result?arch=i586" \
                 "&package=#{package_of_project_with_plus}&repository=#{repo_leap_45_1}&view=status"
          stub_request(:get, path).and_return(body:
            %(<resultlist state='123'>
               <result project='#{source_project_with_plus}' repository='#{repo_leap_45_1}' arch='i586'>
                 <binarylist/>
               </result>
              </resultlist>))
          do_request project: source_project_with_plus, package: package_of_project_with_plus,
                     repository: repo_leap_45_1.name, arch: 'i586', format: 'js'
        end

        it { expect(response).to have_http_status(:ok) }
      end

      context 'with a protected package' do
        let!(:flag) { create(:sourceaccess_flag, project: source_project) }

        before do
          do_request project: source_project, package: source_package, repository: repo_leap_42_2.name, arch: 'i586', format: 'js'
        end

        it { expect(flash[:error]).to eq('Could not access build log') }
        it { expect(response).to redirect_to(package_show_path(project: source_project, package: source_package)) }
      end

      context 'with a non existant package' do
        before do
          do_request project: source_project, package: 'nonexistant', repository: repo_leap_42_2.name, arch: 'i586'
        end

        it { expect(flash[:error]).to eq("Couldn't find package 'nonexistant' in project '#{source_project}'. Are you sure it exists?") }
        it { expect(response).to redirect_to(project_show_path(project: source_project)) }
      end

      context 'with a non existant project' do
        before do
          do_request project: 'home:foo', package: 'nonexistant', repository: repo_leap_42_2.name, arch: 'i586'
        end

        it { expect(flash[:error]).to eq("Couldn't find project 'home:foo'. Are you sure it still exists?") }
        it { expect(response).to redirect_to(root_path) }
      end
    end

    describe 'GET #package_live_build_log' do
      def do_request(params)
        get :live_build_log, params: params
      end

      it_behaves_like 'build log'

      context 'with a nonexistant repository' do
        before do
          do_request project: source_project, package: source_package, repository: 'nonrepository', arch: 'i586'
        end

        it { expect(flash[:error]).not_to be_nil }
        it { expect(response).to redirect_to(package_show_path(source_project, source_package)) }
      end

      context 'with a nonexistant architecture' do
        before do
          do_request project: source_project, package: source_package, repository: repo_leap_42_2.name, arch: 'i566'
        end

        it { expect(flash[:error]).not_to be_nil }
        it { expect(response).to redirect_to(package_show_path(source_project, source_package)) }
      end

      context 'with a multibuild package' do
        let(:params) do
          { project: source_project,
            package: "#{source_package}:multibuild-package",
            repository: repo_leap_42_2.name,
            arch: architecture.name }
        end
        let(:starttime) { 1.hour.ago.to_i }

        before do
          path = "#{CONFIG['source_url']}/build/#{source_project}/_result?arch=i586" \
                 "&package=#{source_package}:multibuild-package&repository=#{repo_leap_42_2}&view=status"
          stub_request(:get, path).and_return(body: %(<resultlist state='123'>
               <result project='#{source_project}' repository='#{repo_leap_42_2}' arch='i586' code="unpublished" state="unpublished">
                <status package="#{source_package}:multibuild-package" code="succeeded" />
               </result>
              </resultlist>))

          path = "#{CONFIG['source_url']}/build/#{source_project}/#{repo_leap_42_2}/i586/_builddepinfo" \
                 "?package=#{source_package}:multibuild-package&view=revpkgnames"
          stub_request(:get, path).and_return(body: %(<builddepinfo>
                <package name="#{source_package}:multibuild-package">
                <source>apache2</source>
                <pkgdep>apache2</pkgdep>
                </package>
              </builddepinfo>))

          Timecop.freeze(Time.now) do
            path = "#{CONFIG['source_url']}/build/#{source_project}/#{repo_leap_42_2}/i586/#{source_package}:multibuild-package/_jobstatus"
            body = "<jobstatus workerid='42' starttime='#{starttime}'/>"
            stub_request(:get, path).and_return(body: body)

            do_request params
          end
        end

        it { expect(assigns(:what_depends_on)).to eq(['apache2']) }
        it { expect(assigns(:status)).to eq('succeeded') }
        it { expect(assigns(:workerid)).to eq('42') }
        it { expect(assigns(:buildtime)).to eq(1.hour.to_i) }
        it { expect(assigns(:package)).to eq(source_package) }
        it { expect(assigns(:package_name)).to eq("#{source_package}:multibuild-package") }
      end
    end

    describe 'GET #update_build_log' do
      def do_request(params)
        get :update_build_log, params: params, xhr: true
      end

      it_behaves_like 'build log'

      context 'with a nonexistant repository' do
        before do
          do_request project: source_project, package: source_package, repository: 'nonrepository', arch: 'i586'
        end

        it { expect(assigns(:errors)).not_to be_nil }
        it { expect(response).to have_http_status(:ok) }
      end

      context 'with a nonexistant architecture' do
        before do
          do_request project: source_project, package: source_package, repository: repo_leap_42_2.name, arch: 'i566'
        end

        it { expect(assigns(:errors)).not_to be_nil }
        it { expect(response).to have_http_status(:ok) }
      end

      context 'for multibuild package' do
        let(:params) do
          { project: source_project,
            package: "#{source_package}:multibuild-package",
            repository: repo_leap_42_2.name,
            arch: architecture.name }
        end

        before do
          path = "#{CONFIG['source_url']}/build/#{source_project}/#{repo_leap_42_2}/i586/#{source_package}:multibuild-package/_log?view=entry"
          body = "<directory><entry name=\"_log\" size=\"#{32 * 1024}\" mtime=\"1492267770\" /></directory>"
          stub_request(:get, path).and_return(body: body)
          do_request params
        end

        it { expect(assigns(:log_chunk)).not_to be_nil }
        it { expect(assigns(:package)).to eq(source_package) }
        it { expect(assigns(:package_name)).to eq("#{source_package}:multibuild-package") }
        it { expect(assigns(:project)).to eq(source_project) }
        it { expect(assigns(:offset)).to eq(0) }
      end
    end
  end

  describe 'POST #trigger_rebuild' do
    before do
      login(user)
    end

    context 'when triggering a rebuild fails' do
      before do
        post :trigger_rebuild, params: { project: source_project, package: source_package, repository: 'non_existant_repository' }
      end

      it 'lets the user know there was an error' do
        expect(flash[:error]).to match('Error while triggering rebuild for home:tom/my_package')
      end

      it 'redirects to the package binaries path' do
        expect(response).to redirect_to(package_binaries_path(project: source_project, package: source_package,
                                                              repository: 'non_existant_repository'))
      end
    end

    context 'when triggering a rebuild succeeds' do
      let!(:repository) { create(:repository, project: source_project, architectures: ['i586'], name: 'openSUSE_Leap_15.1') }

      before do
        source_project.store

        post :trigger_rebuild, params: { project: source_project, package: source_package, repository: repository.name, arch: 'i586' }
      end

      it { expect(flash[:success]).to eq("Triggered rebuild for #{source_project.name}/#{source_package.name} successfully.") }
      it { expect(response).to redirect_to(package_show_path(project: source_project, package: source_package)) }
    end

    context 'when triggering a rebuild with maintainer of package' do
      let(:user) { create(:confirmed_user, login: 'foo') }
      let(:other_user) { create(:confirmed_user, login: 'bar') }
      let!(:project) { create(:project, name: 'foo_project', maintainer: user) }
      let!(:repository) { create(:repository, project: project, architectures: ['i586'], name: 'openSUSE_Leap_15.1') }
      let!(:package_with_maintainer) { create(:package_with_maintainer, maintainer: other_user, project: project, name: 'package_1') }

      before do
        login other_user
        project.store
        post :trigger_rebuild, params: { project: project, package: package_with_maintainer,
                                         repository: repository.name, arch: 'i586' }
      end

      it { expect(flash[:success]).not_to be_nil }
    end

    context 'when triggering a rebuild fails' do
      let(:user) { create(:confirmed_user, login: 'foo') }
      let(:other_user) { create(:confirmed_user, login: 'bar') }
      let(:project) { create(:project, name: 'foo_project') }
      let!(:package_with_maintainer) { create(:package_with_maintainer, maintainer: user, project: project) }

      before do
        login other_user
        post :trigger_rebuild, params: { project: project, package: package_with_maintainer }
      end

      it { expect(flash[:success]).to be_nil }
      it { expect(flash[:error]).not_to be_nil }
    end
  end

  describe 'POST #abort_build' do
    before do
      login(user)
    end

    context 'when aborting the build fails' do
      before do
        post :abort_build, params: { project: source_project, package: source_package, repository: 'foo', arch: 'bar' }
      end

      it 'lets the user know there was an error' do
        expect(flash[:error]).to match('Error while triggering abort build for home:tom/my_package')
        expect(flash[:error]).to match('no repository defined')
      end

      it {
        expect(response).to redirect_to(package_live_build_log_path(project: source_project,
                                                                    package: source_package,
                                                                    repository: 'foo', arch: 'bar'))
      }
    end

    context 'when aborting the build succeeds' do
      before do
        create(:repository, project: source_project, architectures: ['i586'])
        source_project.store

        post :abort_build, params: { project: source_project, package: source_package }
      end

      it { expect(flash[:success]).to eq("Triggered abort build for #{source_project.name}/#{source_package.name} successfully.") }
      it { expect(response).to redirect_to(package_show_path(project: source_project, package: source_package)) }
    end
  end

  # FIXME: This should be feature specs
  describe 'GET #statistics' do
    let!(:repository) { create(:repository, name: 'statistics', project: source_project, architectures: ['i586']) }

    before do
      login(user)

      # Save the repository in backend
      source_project.store
    end

    context 'when backend returns statistics' do
      render_views

      before do
        allow(Backend::Api::BuildResults::Status).to receive(:statistics)
          .with(source_project.name, source_package.name, repository.name, 'i586')
          .and_return('<buildstatistics><disk><usage><size unit="M">30</size></usage></disk></buildstatistics>')

        get :statistics, params: { project: source_project.name, package: source_package.name, arch: 'i586', repository: repository.name }
      end

      it { expect(assigns(:statistics).disk).to have_attributes(size: '30', unit: 'M', io_requests: nil, io_sectors: nil) }
      it { expect(response).to have_http_status(:success) }
    end

    context 'when backend does not return statistics' do
      let(:get_statistics) { get :statistics, params: { project: source_project.name, package: source_package.name, arch: 'i586', repository: repository.name } }

      it { expect(assigns(:statistics)).to be_nil }
    end

    context 'when backend raises an exception' do
      before do
        allow(Backend::Api::BuildResults::Status).to receive(:statistics)
          .with(source_project.name, source_package.name, repository.name, 'i586')
          .and_raise(Backend::NotFoundError)
      end

      let(:get_statistics) { get :statistics, params: { project: source_project.name, package: source_package.name, arch: 'i586', repository: repository.name } }

      it { expect(assigns(:statistics)).to be_nil }
    end
  end

  describe '#rpmlint_result' do
    let(:fake_build_result) do
      <<-XML
        <resultlist state="eb0459ee3b000176bb3944a67b7c44fa">
          <result project="home:tom" repository="openSUSE_Tumbleweed" arch="i586" code="building" state="building">
            <status package="my_package" code="excluded" />
          </result>
          <result project="home:tom" repository="openSUSE_Leap_42.1" arch="armv7l" code="unknown" state="unknown" />
          <result project="home:tom" repository="openSUSE_Leap_42.1" arch="x86_64" code="building" state="building">
            <status package="my_package" code="signing" />
          </result>
          <result project="home:tom" repository="images" arch="x86_64" code="building" state="building">
            <status package="my_package" code="signing" />
          </result>
        </resultlist>
      XML
    end

    before do
      allow(Backend::Api::BuildResults::Status).to receive(:result_swiss_knife).and_return(fake_build_result)
      post :rpmlint_result, xhr: true, params: { package: source_package, project: source_project }
    end

    it { expect(response).to have_http_status(:success) }
    it { expect(assigns(:repo_list)).to include(['openSUSE_Leap_42.1', 'openSUSE_Leap_42_1']) }
    it { expect(assigns(:repo_list)).not_to include(['images', 'images']) }
    it { expect(assigns(:repo_list)).not_to include(['openSUSE_Tumbleweed', 'openSUSE_Tumbleweed']) }
    it { expect(assigns(:repo_arch_hash)['openSUSE_Leap_42_1']).to include('x86_64') }
    it { expect(assigns(:repo_arch_hash)['openSUSE_Leap_42_1']).not_to include('armv7l') }
  end

  describe 'GET #rpmlint_log' do
    describe 'when no rpmlint log is available' do
      render_views

      subject do
        get :rpmlint_log, params: { project: source_project, package: source_package, repository: repo_for_source_project.name, architecture: 'i586' }
      end

      it { is_expected.to have_http_status(:success) }
      it { expect(subject.body).to eq('No rpmlint log') }
    end

    describe 'when there is a rpmlint log' do
      before do
        allow(Backend::Api::BuildResults::Binaries).to receive(:rpmlint_log)
          .with(source_project.name, source_package.name, repo_for_source_project.name, 'i586')
          .and_return('test_package.i586: W: description-shorter-than-summary\ntest_package.src: W: description-shorter-than-summary')
      end

      subject do
        get :rpmlint_log, params: { project: source_project, package: source_package, repository: repo_for_source_project.name, architecture: 'i586' }
      end

      it { is_expected.to have_http_status(:success) }
      it { is_expected.to render_template('webui/package/_rpmlint_log') }
    end
  end

  describe 'POST #create' do
    let(:package_name) { 'new-package' }
    let(:my_user) { user }
    let(:post_params) do
      { project: source_project,
        package: { name: package_name, title: 'package foo', description: 'awesome package foo' } }
    end

    context 'Package#save failed' do
      before do
        login(my_user)
        post :create, params: post_params.merge(package: { name: package_name, title: 'a' * 251 })
      end

      it { expect(response).to redirect_to(project_show_path(source_project)) }
      it { expect(flash[:error]).to eq('Failed to create package: Title is too long (maximum is 250 characters)') }
    end

    context 'package creation' do
      before do
        login(my_user)
        post :create, params: post_params
      end

      context 'valid package name' do
        it { expect(response).to redirect_to(package_show_path(source_project, package_name)) }
        it { expect(flash[:success]).to eq("Package 'new-package' was created successfully") }
        it { expect(Package.find_by(name: package_name).flags).to be_empty }
      end

      context 'valid package with source_protection enabled' do
        let(:post_params) do
          { project: source_project, source_protection: 'foo', disable_publishing: 'bar',
            package: { name: package_name, title: 'package foo', description: 'awesome package foo' } }
        end

        it { expect(Package.find_by(name: package_name).flags).to include(Flag.find_by_flag('sourceaccess')) }
        it { expect(Package.find_by(name: package_name).flags).to include(Flag.find_by_flag('publish')) }
      end

      context 'invalid package name' do
        let(:package_name) { 'A' * 250 }

        it { expect(response).to redirect_to(new_package_path(source_project)) }
        it { expect(flash[:error]).to match("Invalid package name:\s.*") }
      end

      context 'package already exist' do
        let(:package_name) { package.name }

        it { expect(response).to redirect_to(new_package_path(source_project)) }
        it { expect(flash[:error]).to start_with("Package '#{package.name}' already exists in project") }
      end

      context 'not allowed to create package in' do
        let(:package_name) { 'foo' }
        let(:my_user) { create(:confirmed_user, login: 'another_user') }

        it { expect(response).to redirect_to(root_path) }
        it { expect(flash[:error]).to eq('Sorry, you are not authorized to create this package.') }
      end
    end
  end

  describe 'GET #edit' do
    context 'when the user is authorized to edit the package' do
      before do
        login(user)
        get :edit, xhr: true, params: { project: source_project, package: source_package }, format: :js
      end

      it { expect(response).to have_http_status(:success) }
      it { expect(assigns[:project]).to eql(source_project) }
      it { expect(assigns[:package]).to eql(source_package) }
    end

    context 'when the user is NOT authorized to edit the package' do
      let(:admins_home_project) { admin.home_project }
      let(:package_from_admin) do
        create(:package, name: 'admins_package', project: admins_home_project)
      end

      before do
        login(user)
        get :edit, params: { project: admins_home_project, package: package_from_admin }
      end

      it { expect(response).to redirect_to(root_path) }
    end
  end

  describe 'PATCH #update' do
    context 'when the user is authorized to change the package' do
      let(:package_params) do
        {
          title: 'Updated title',
          url: 'https://updated.url',
          description: 'Updated description.'
        }
      end

      before do
        login(user)
        patch :update,
              params: {
                project: source_project,
                package_details: package_params,
                package: source_package.name
              },
              format: :js
      end

      it { expect(response).to have_http_status(:success) }
      it { expect(assigns(:package).title).to eql(package_params[:title]) }
      it { expect(assigns(:package).url).to eql(package_params[:url]) }
      it { expect(assigns(:package).description).to eql(package_params[:description]) }
    end
  end

  context 'when the user is NOT authorized to change the package' do
    let(:package_params) do
      {
        title: 'Updated title',
        url: 'https://updated.url',
        description: 'Updated description.'
      }
    end
    let(:admins_home_project) { admin.home_project }
    let(:package_from_admin) do
      create(:package, name: 'admins_package', project: admins_home_project)
    end

    before do
      login(user)
      patch :update,
            params: {
              project: admins_home_project,
              package_details: package_params,
              package: package_from_admin.name
            }
    end

    it { expect(response).to redirect_to(root_path) }
  end
end
