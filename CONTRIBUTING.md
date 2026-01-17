# Contributing to Proxmox Automation Toolkit

Thank you for your interest in contributing! This project provides opinionated automation for Proxmox storage and cloud-init template management. We welcome contributions that improve reliability, add features, or enhance documentation.

## Project Structure

All source code lives in the `src/` directory:
- `proxmox-storage.sh` - Storage discovery and provisioning
- `proxmox-templates.sh` - Cloud-init template builder
- `config/` - Template build configurations (YAML)
- `distros/` - Distribution-specific configurations
- `catalog/` - Available release catalogs

## Getting Started

Before you begin, make sure you have:
- A GitHub account and basic Git knowledge
- Access to a Proxmox VE test environment
- Familiarity with Bash scripting and YAML

Helpful resources:
- [Git Documentation](https://git-scm.com/doc)
- [GitHub Quickstart Guide](https://docs.github.com/en/get-started/quickstart)
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)

## How to Submit Changes

To contribute to this project, follow these detailed steps:

### 1. Fork the Repository
Click on the 'Fork' button at the top right of this page. This creates a copy of the codebase under your GitHub profile, allowing you to experiment and make changes without affecting the original project.

### 2. Clone Your Fork
On your local machine, clone the forked repository to work with the files:
```bash
git clone https://github.com/your-username/cloud-image-for-proxmox.git
cd cloud-image-for-proxmox
```

### 3. Create a New Branch
Create a branch for your changes. This helps isolate new development work and makes the merging process straightforward:
```bash
git checkout -b your-new-branch-name
```

### 4. Make Your Changes
Update existing files or add new features to the repository. Keep your changes as focused as possible. This not only makes the review process easier but also increases the chance of your pull request being accepted.

#### Follow Our Coding Standards
Ensure all code adheres to the standards outlined in our [Style Guide](STYLE_GUIDE.md). This includes:
- Using proper naming conventions
- Writing idempotent scripts (safe to run multiple times)
- Implementing comprehensive error handling
- Using colored output for status messages
- Commenting your code where necessary
- Following the architectural layout of the project

### 5. Test Thoroughly
Before submitting your changes, test them in a Proxmox environment:
- **Storage scripts**: Test on systems with various disk configurations
- **Template scripts**: Verify builds complete successfully
- **Configuration changes**: Run `--validate` to check YAML syntax
- **Documentation**: Ensure all examples are accurate and work as written

Our project strives for production-ready reliability, and your contributions should reflect this standard.

### 6. Update Documentation
If your changes involve user-facing features or configurations, update the relevant documentation files with clear, concise, and comprehensive details. This is crucial for ensuring all users can successfully utilize new features.

### 7. Commit Your Changes
Use clear and meaningful commit messages. This helps the review process and future maintenance:
```bash
git add .
git commit -m "Add a concise commit title and a detailed description of what was changed and why"
```

### 8. Push to Your Fork
Push your branch and changes to your GitHub fork:
```bash
git push origin your-new-branch-name
```

### 9. Submit a Pull Request
Go to your fork on GitHub, click on the ‘New pull request’ button, and select your branch. Provide a detailed description of your changes and any other relevant information to reviewers.
## Contribution Guidelines

### Code Quality
- Follow the [Style Guide](STYLE_GUIDE.md) for all Bash scripts
- Use `shellcheck` to validate scripts before submitting
- Ensure scripts work on Proxmox VE 8.x and later
- Test in clean environments (not just your customized setup)

### Configuration Files
- YAML files must pass validation (`yq` syntax check)
- Follow existing structure and naming conventions
- Document any new configuration options
- Provide examples for new features

### Documentation
- Update relevant `.md` files for user-facing changes
- Keep examples up-to-date with code changes
- Use clear, concise language
- Include both "quick start" and detailed explanations

### What We're Looking For
- 🎯 **Bug fixes** - Issues that affect functionality
- ✨ **New distributions** - Support for additional Linux distros
- 📚 **Documentation** - Improvements to clarity or completeness
- 🚀 **Features** - Enhancements that maintain simplicity
- 🧪 **Tests** - Validation scripts or test frameworks

### What to Avoid
- ❌ Breaking changes without discussion
- ❌ Features that add significant complexity
- ❌ Reformatting existing code without functional changes
- ❌ Pull requests without testing
## Pull Request Review Process

All pull requests undergo a review process where maintainers look at the ease of integration, completeness of contributions, and adherence to the project’s standards. We aim to review contributions within one week of submission.

## Resources

- [Github - Collaborating with Pull Requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request)
- [Google Engineering - Code Review Best Practices](https://google.github.io/eng-practices/review/)
